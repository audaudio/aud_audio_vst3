// @license
// Copyright (c) Audanika. All Rights Reserved.
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

#include "aud_vst3_socket.hpp"

#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <stdlib.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <unistd.h>

#include <cstdio>
#include <cstring>

namespace aud_vst3 {

namespace {

// The largest frame either side accepts (AudShellCodec.maxFrame).
constexpr uint32_t kMaxFrame = 16u << 20;
// Above this, droppable messages are dropped.
constexpr size_t kOutboxLimit = 4u << 20;
// Above this, the editor is taken as hung and its connection is closed.
constexpr size_t kOutboxHardLimit = 32u << 20;

void setNonBlocking(int fd) {
  fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK);
  fcntl(fd, F_SETFD, FD_CLOEXEC);
}

std::string frameOf(const aud::Json& message) {
  std::string body;
  aud::writeJson(message, 0, &body);
  std::string frame(4, '\0');
  const uint32_t length = static_cast<uint32_t>(body.size());
  frame[0] = static_cast<char>(length & 0xff);
  frame[1] = static_cast<char>((length >> 8) & 0xff);
  frame[2] = static_cast<char>((length >> 16) & 0xff);
  frame[3] = static_cast<char>((length >> 24) & 0xff);
  return frame + body;
}

}  // namespace

SocketServer::SocketServer(MessageHandler onMessage, StateHandler onState)
    : onMessage_(std::move(onMessage)), onState_(std::move(onState)) {}

SocketServer::~SocketServer() {
  stopping_ = true;
  wake();
  if (thread_.joinable()) thread_.join();
  if (connFd_ >= 0) close(connFd_);
  if (listenFd_ >= 0) close(listenFd_);
  if (wake_[0] >= 0) close(wake_[0]);
  if (wake_[1] >= 0) close(wake_[1]);
  if (!path_.empty()) unlink(path_.c_str());
}

bool SocketServer::start(const std::string& directory) {
  char name[64];
  std::snprintf(name, sizeof(name), "/aud-vst3-%d-%08x.sock", getpid(),
                arc4random());
  path_ = directory + name;
  sockaddr_un address{};
  address.sun_family = AF_UNIX;
  if (path_.size() >= sizeof(address.sun_path)) return false;
  std::memcpy(address.sun_path, path_.c_str(), path_.size() + 1);
  listenFd_ = socket(AF_UNIX, SOCK_STREAM, 0);
  if (listenFd_ < 0) return false;
  setNonBlocking(listenFd_);
  unlink(path_.c_str());
  if (bind(listenFd_, reinterpret_cast<sockaddr*>(&address), sizeof(address)) !=
          0 ||
      chmod(path_.c_str(), 0600) != 0 || listen(listenFd_, 2) != 0) {
    return false;
  }
  if (pipe(wake_) != 0) return false;
  setNonBlocking(wake_[0]);
  setNonBlocking(wake_[1]);
  thread_ = std::thread([this] { loop(); });
  return true;
}

void SocketServer::send(const aud::Json& message, bool droppable) {
  std::string frame = frameOf(message);
  {
    std::lock_guard<std::mutex> lock(mutex_);
    if (connection_ == 0) return;
    if (droppable && outboxBytes_ > kOutboxLimit) {
      dropped_.fetch_add(1, std::memory_order_relaxed);
      return;
    }
    if (outboxBytes_ + frame.size() > kOutboxHardLimit) {
      // The editor reads nothing: its connection ends, and its owner kills
      // and restarts it.
      dropped_.fetch_add(1, std::memory_order_relaxed);
      if (disconnectRequested_ != connection_) {
        disconnectRequested_ = connection_;
        overflows_.fetch_add(1, std::memory_order_relaxed);
      }
    } else {
      outboxBytes_ += frame.size();
      outbox_.push_back(std::move(frame));
    }
  }
  wake();
}

void SocketServer::authenticate(uint64_t connection) {
  std::lock_guard<std::mutex> lock(mutex_);
  if (connection_ == connection) authenticated_ = connection;
}

void SocketServer::disconnect(uint64_t connection) {
  {
    std::lock_guard<std::mutex> lock(mutex_);
    if (connection_ != connection) return;
    disconnectRequested_ = connection;
  }
  wake();
}

void SocketServer::wake() {
  if (wake_[1] < 0) return;
  const char byte = 1;
  (void)write(wake_[1], &byte, 1);
}

void SocketServer::closeConnection() {
  if (connFd_ < 0) return;
  close(connFd_);
  connFd_ = -1;
  inbox_.clear();
  writing_.clear();
  written_ = 0;
  uint64_t ended = 0;
  {
    std::lock_guard<std::mutex> lock(mutex_);
    ended = connection_;
    connection_ = 0;
    authenticated_ = 0;
    outbox_.clear();
    outboxBytes_ = 0;
  }
  onState_(false, ended);
}

// A new connection replaces one that is not authenticated or already gone;
// while the editor's connection lives, a further one is refused.
void SocketServer::accept() {
  const int fd = ::accept(listenFd_, nullptr, nullptr);
  if (fd < 0) return;
  setNonBlocking(fd);
  const int on = 1;
  setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, sizeof(on));
  if (connFd_ >= 0) {
    bool authenticated = false;
    {
      std::lock_guard<std::mutex> lock(mutex_);
      authenticated = authenticated_ != 0 && authenticated_ == connection_;
    }
    char byte = 0;
    const ssize_t n = recv(connFd_, &byte, 1, MSG_PEEK | MSG_DONTWAIT);
    const bool alive = n > 0 || (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK));
    if (authenticated && alive) {
      close(fd);
      return;
    }
    closeConnection();
  }
  connFd_ = fd;
  const uint64_t connection = ++lastConnection_;
  {
    std::lock_guard<std::mutex> lock(mutex_);
    connection_ = connection;
    authenticated_ = 0;
    disconnectRequested_ = 0;
  }
  onState_(true, connection);
}

bool SocketServer::readFrom(int fd) {
  char buffer[65536];
  bool open = true;
  for (;;) {
    const ssize_t n = read(fd, buffer, sizeof(buffer));
    if (n > 0) {
      inbox_.append(buffer, static_cast<size_t>(n));
      continue;
    }
    if (n == 0) {
      open = false;
      break;
    }
    if (errno == EAGAIN || errno == EWOULDBLOCK) break;
    if (errno == EINTR) continue;
    open = false;
    break;
  }
  // Frames that arrived together with the end of the connection count.
  return parseFrames() && open;
}

bool SocketServer::parseFrames() {
  const uint64_t connection = lastConnection_;
  size_t offset = 0;
  while (inbox_.size() - offset >= 4) {
    const auto* bytes = reinterpret_cast<const uint8_t*>(inbox_.data() + offset);
    const uint32_t length = bytes[0] | (bytes[1] << 8) | (bytes[2] << 16) |
                            (static_cast<uint32_t>(bytes[3]) << 24);
    if (length > kMaxFrame) return false;
    if (inbox_.size() - offset - 4 < length) break;
    aud::Json message;
    std::string error;
    if (!aud::parseJson(inbox_.data() + offset + 4, length, &message, &error)) {
      return false;
    }
    offset += 4 + length;
    onMessage_(message, connection);
  }
  inbox_.erase(0, offset);
  return true;
}

void SocketServer::loop() {
  while (!stopping_) {
    bool wantWrite = !writing_.empty();
    if (!wantWrite && connFd_ >= 0) {
      std::lock_guard<std::mutex> lock(mutex_);
      wantWrite = !outbox_.empty();
    }
    pollfd fds[3] = {{wake_[0], POLLIN, 0}, {listenFd_, POLLIN, 0},
                     {connFd_, static_cast<short>(POLLIN | (wantWrite ? POLLOUT : 0)), 0}};
    const nfds_t count = connFd_ >= 0 ? 3 : 2;
    if (poll(fds, count, 1000) < 0 && errno != EINTR) break;
    if (stopping_) break;
    if (fds[0].revents & POLLIN) {
      char drain[256];
      while (read(wake_[0], drain, sizeof(drain)) > 0) {
      }
    }
    {
      bool requested = false;
      {
        std::lock_guard<std::mutex> lock(mutex_);
        requested = disconnectRequested_ != 0 && disconnectRequested_ == connection_;
        disconnectRequested_ = 0;
      }
      if (requested) closeConnection();
    }
    if (fds[1].revents & POLLIN) {
      accept();
      continue;
    }
    if (connFd_ < 0) continue;
    if ((count == 3) && (fds[2].revents & (POLLIN | POLLHUP | POLLERR))) {
      if (!readFrom(connFd_)) {
        closeConnection();
        continue;
      }
    }
    // Writes as much as the socket takes.
    for (;;) {
      if (writing_.empty()) {
        std::lock_guard<std::mutex> lock(mutex_);
        if (outbox_.empty()) break;
        writing_ = std::move(outbox_.front());
        outbox_.pop_front();
        outboxBytes_ -= writing_.size();
        written_ = 0;
      }
      const ssize_t n = write(connFd_, writing_.data() + written_,
                              writing_.size() - written_);
      if (n > 0) {
        written_ += static_cast<size_t>(n);
        if (written_ == writing_.size()) {
          writing_.clear();
          written_ = 0;
        }
        continue;
      }
      if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) break;
      if (n < 0 && errno == EINTR) continue;
      closeConnection();
      break;
    }
  }
}

}  // namespace aud_vst3
