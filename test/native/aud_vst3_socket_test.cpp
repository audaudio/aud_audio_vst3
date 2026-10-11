// @license
// Copyright (c) Audanika. All Rights Reserved.
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

#include "aud_vst3_socket.hpp"

#include <poll.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <unistd.h>

#include <chrono>
#include <condition_variable>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <memory>
#include <mutex>
#include <string>
#include <vector>

#include "aud_json.hpp"

#include "aud_vst3_harness.hpp"

using aud_vst3::SocketServer;
using aud_vst3_test::expectEqual;
using aud_vst3_test::group;
using aud_vst3_test::test;
using Strings = std::vector<std::string>;

namespace {

// How long a test waits for the server.
constexpr int kTimeoutMs = 2000;

// How long a test waits before it takes it that nothing comes.
constexpr int kQuietMs = 200;

// The largest frame the server takes (AudShellCodec.maxFrame).
constexpr uint32_t kMaxFrame = 16u << 20;

// What the handlers of a server learn on its IPC thread, in order:
// "started <connection>", every message as compact JSON and
// "ended <connection>".
class Events {
 public:
  // The message handler of the server.
  SocketServer::MessageHandler onMessage() {
    return [this](const aud::Json& message, uint64_t) {
      std::string text;
      aud::writeJson(message, 0, &text);
      add(text);
    };
  }

  // The state handler of the server.
  SocketServer::StateHandler onState() {
    return [this](bool connected, uint64_t connection) {
      add((connected ? "started " : "ended ") + std::to_string(connection));
    };
  }

  // The events once there are `count`, or those after `ms`.
  Strings wait(size_t count, int ms = kTimeoutMs) {
    std::unique_lock<std::mutex> lock(mutex_);
    changed_.wait_for(lock, std::chrono::milliseconds(ms),
                      [&] { return events_.size() >= count; });
    return events_;
  }

 private:
  void add(const std::string& event) {
    std::lock_guard<std::mutex> lock(mutex_);
    events_.push_back(event);
    changed_.notify_all();
  }

  std::mutex mutex_;
  std::condition_variable changed_;
  Strings events_;
};

// A client of a server's socket; the connection ends with the object.
class Client {
 public:
  // Connects to the socket at `path`.
  explicit Client(const std::string& path)
      : fd_(socket(AF_UNIX, SOCK_STREAM, 0)) {
    const int on = 1;
    setsockopt(fd_, SOL_SOCKET, SO_NOSIGPIPE, &on, sizeof(on));
    sockaddr_un address{};
    address.sun_family = AF_UNIX;
    std::snprintf(address.sun_path, sizeof(address.sun_path), "%s",
                  path.c_str());
    connect(fd_, reinterpret_cast<sockaddr*>(&address), sizeof(address));
  }

  // Ends the connection.
  ~Client() { close(fd_); }

  // Not copyable: the object owns the socket.
  Client(const Client&) = delete;
  Client& operator=(const Client&) = delete;

  // Writes `bytes`.
  void write(const std::string& bytes) {
    size_t written = 0;
    while (written < bytes.size()) {
      const ssize_t n =
          ::write(fd_, bytes.data() + written, bytes.size() - written);
      if (n <= 0) return;
      written += static_cast<size_t>(n);
    }
  }

  // Ends the sending side: the server reads the end of the connection.
  void finish() { shutdown(fd_, SHUT_WR); }

  // The body of the first frame that arrives within `ms`; empty when none
  // arrives.
  std::string receive(int ms) {
    const auto deadline =
        std::chrono::steady_clock::now() + std::chrono::milliseconds(ms);
    std::string bytes;
    while (std::chrono::steady_clock::now() < deadline) {
      if (bytes.size() >= 4) {
        const auto* b = reinterpret_cast<const uint8_t*>(bytes.data());
        const size_t length = b[0] | (b[1] << 8) | (b[2] << 16) |
                              (static_cast<uint32_t>(b[3]) << 24);
        if (bytes.size() >= 4 + length) return bytes.substr(4, length);
      }
      pollfd readable = {fd_, POLLIN, 0};
      if (poll(&readable, 1, 10) <= 0) continue;
      char buffer[4096];
      const ssize_t n = read(fd_, buffer, sizeof(buffer));
      if (n <= 0) return {};
      bytes.append(buffer, static_cast<size_t>(n));
    }
    return {};
  }

  // Whether the server ends the connection within kTimeoutMs.
  bool ended() {
    pollfd readable = {fd_, POLLIN, 0};
    if (poll(&readable, 1, kTimeoutMs) <= 0) return false;
    char byte = 0;
    return read(fd_, &byte, 1) <= 0;
  }

 private:
  const int fd_;
};

}  // namespace

int main() {
  // The directory of the sockets, as the plugin picks it.
  const std::string directory = [] {
    const char* tmp = std::getenv("TMPDIR");
    std::string dir = tmp != nullptr ? tmp : "/tmp";
    while (dir.size() > 1 && dir.back() == '/') dir.pop_back();
    return dir;
  }();
  // A started server that tells `events`.
  const auto serve = [&](Events& events) {
    auto server =
        std::make_unique<SocketServer>(events.onMessage(), events.onState());
    expectEqual(server->start(directory), true);
    return server;
  };
  // The length of a frame in its 4 bytes, little-endian.
  const auto lengthOf = [](uint32_t length) {
    std::string bytes;
    for (int shift = 0; shift < 32; shift += 8) {
      bytes += static_cast<char>((length >> shift) & 0xff);
    }
    return bytes;
  };
  // `body` as the shell protocol frames it.
  const auto frameOf = [&](const std::string& body) {
    return lengthOf(static_cast<uint32_t>(body.size())) + body;
  };
  // A message of the shell protocol of type `type`.
  const auto message = [](const char* type) {
    aud::Json json = aud::Json::ofObject();
    json.set("type", aud::Json::ofString(type));
    return json;
  };
  const std::string hello = R"({"type":"hello"})";

  group("SocketServer", [&] {
    group("start(directory)", [&] {
      test("creates the socket in the directory", [&] {
        Events events;
        const auto server = serve(events);
        struct stat info {};
        expectEqual(server->path().rfind(directory + "/aud-vst3-", 0),
                    size_t{0});
        expectEqual(stat(server->path().c_str(), &info) == 0 &&
                        S_ISSOCK(info.st_mode),
                    true);
      });
    });

    group("onMessage(message, connection)", [&] {
      test("receives a frame split across two reads", [&] {
        Events events;
        const auto server = serve(events);
        Client client(server->path());
        const std::string frame = frameOf(hello);
        client.write(frame.substr(0, 7));
        expectEqual(events.wait(2, kQuietMs), Strings{"started 1"});
        client.write(frame.substr(7));
        expectEqual(events.wait(2), Strings{"started 1", hello});
      });

      test("receives two frames of one read", [&] {
        Events events;
        const auto server = serve(events);
        Client client(server->path());
        const std::string first = R"({"type":"first"})";
        const std::string second = R"({"type":"second"})";
        client.write(frameOf(first) + frameOf(second));
        expectEqual(events.wait(3), Strings{"started 1", first, second});
      });

      test("receives a frame that arrives with the end of the connection",
           [&] {
             Events events;
             const auto server = serve(events);
             Client client(server->path());
             client.write(frameOf(hello));
             client.finish();
             expectEqual(events.wait(3),
                         Strings{"started 1", hello, "ended 1"});
           });
    });

    group("onState(connected, connection)", [&] {
      test("ends a connection that announces a frame above the limit", [&] {
        Events events;
        const auto server = serve(events);
        Client client(server->path());
        client.write(lengthOf(kMaxFrame + 1));
        expectEqual(events.wait(2), Strings{"started 1", "ended 1"});
        expectEqual(client.ended(), true);
      });

      test("ends a connection that sends no JSON", [&] {
        Events events;
        const auto server = serve(events);
        Client client(server->path());
        client.write(frameOf("{not json"));
        expectEqual(events.wait(2), Strings{"started 1", "ended 1"});
        expectEqual(client.ended(), true);
      });
    });

    group("send(message, droppable)", [&] {
      test("sends nothing to a connection that is not authenticated", [&] {
        Events events;
        const auto server = serve(events);
        Client client(server->path());
        expectEqual(events.wait(1), Strings{"started 1"});
        server->send(message("param"));
        expectEqual(client.receive(kQuietMs), std::string());
      });

      test("sends to the connection once it is authenticated", [&] {
        Events events;
        const auto server = serve(events);
        Client client(server->path());
        expectEqual(events.wait(1), Strings{"started 1"});
        server->send(message("early"));
        server->authenticate(1);
        server->send(message("param"));
        expectEqual(client.receive(kTimeoutMs),
                    std::string(R"({"type":"param"})"));
      });
    });
  });
  return aud_vst3_test::finish();
}
