// @license
// Copyright (c) Audanika. All Rights Reserved.
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

// The plugin's end of the shell protocol (ticket 24, decision 3 of the plan
// review of ticket 23): a Unix domain socket, one connection at a time,
// frames of a 4-byte little-endian length and UTF-8 JSON - the framing of
// AudShellCodec in lib/src/aud_shell_codec.dart.
//
// One IPC thread per server accepts, reads and writes. Every connection
// has an id; received messages and the end of a connection go to the
// handlers on the IPC thread with it, so the owner tells a late message of
// an old connection from one of the current. While an authenticated
// connection lives, further connections are refused; one that is not
// authenticated yet is replaced.
//
// send() may be called from any thread and never blocks: the outbox is
// bounded. Above the soft limit droppable messages (input moves, meters)
// are dropped and counted; above the hard limit the editor is taken as
// hung and its connection is closed, so the host's UI thread never waits
// for the editor and its memory never grows without bound.

#ifndef AUD_VST3_SOCKET_HPP
#define AUD_VST3_SOCKET_HPP

#include <atomic>
#include <cstdint>
#include <deque>
#include <functional>
#include <mutex>
#include <string>
#include <thread>

#include "aud_json.hpp"

namespace aud_vst3 {

class SocketServer {
 public:
  // [IPC thread] A message of connection `connection`.
  using MessageHandler =
      std::function<void(const aud::Json& message, uint64_t connection)>;
  // [IPC thread] Connection `connection` started (true) or ended.
  using StateHandler = std::function<void(bool connected, uint64_t connection)>;

  SocketServer(MessageHandler onMessage, StateHandler onState);
  ~SocketServer();

  SocketServer(const SocketServer&) = delete;
  SocketServer& operator=(const SocketServer&) = delete;

  // Binds a socket under `directory` with a random name and starts the IPC
  // thread; false when the socket cannot be created.
  bool start(const std::string& directory);

  // [any thread] Queues a message for the current connection. A droppable
  // message is dropped above the soft limit; above the hard limit the
  // connection is closed.
  void send(const aud::Json& message, bool droppable = false);

  // [any thread] Marks `connection` as the editor's: it is no longer
  // replaced by a new one.
  void authenticate(uint64_t connection);

  // [any thread] Ends `connection` if it is still the current one; the
  // server keeps listening.
  void disconnect(uint64_t connection);

  // The path of the socket.
  const std::string& path() const { return path_; }

  // The messages dropped, and the connections closed because the outbox
  // overflowed, since the start.
  uint64_t dropped() const { return dropped_.load(std::memory_order_relaxed); }
  uint64_t overflows() const {
    return overflows_.load(std::memory_order_relaxed);
  }

 private:
  void loop();
  void wake();
  void accept();
  bool readFrom(int fd);
  bool parseFrames();
  void closeConnection();

  MessageHandler onMessage_;
  StateHandler onState_;
  std::string path_;
  int listenFd_ = -1;
  int connFd_ = -1;  // IPC thread only
  int wake_[2] = {-1, -1};
  std::string inbox_;    // IPC thread only
  std::string writing_;  // IPC thread only: the frame being written
  size_t written_ = 0;   // IPC thread only

  std::mutex mutex_;
  std::deque<std::string> outbox_;
  size_t outboxBytes_ = 0;
  uint64_t connection_ = 0;      // the current connection, 0 for none
  uint64_t authenticated_ = 0;   // the authenticated connection, 0 for none
  uint64_t disconnectRequested_ = 0;
  uint64_t lastConnection_ = 0;  // IPC thread only

  std::atomic<bool> stopping_{false};
  std::atomic<uint64_t> dropped_{0};
  std::atomic<uint64_t> overflows_{0};
  std::thread thread_;
};

}  // namespace aud_vst3

#endif  // AUD_VST3_SOCKET_HPP
