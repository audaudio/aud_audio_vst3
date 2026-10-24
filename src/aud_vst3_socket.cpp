// @license
// Copyright (c) Audanika. All Rights Reserved.
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

#include "aud_vst3_socket.hpp"

#if _WIN32
#ifndef NOMINMAX
#define NOMINMAX
#endif
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <winsock2.h>
#include <afunix.h>
#include <windows.h>

#include <random>
#else
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <stdlib.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <unistd.h>
#endif

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

// .............................................................................
// The calls of the platform's sockets: POSIX, or Winsock on Windows.

#if _WIN32
using Native = SOCKET;
using PollEntry = WSAPOLLFD;

void closeSocket(Native fd) { closesocket(fd); }

void setNonBlocking(Native fd) {
  u_long on = 1;
  ioctlsocket(fd, FIONBIO, &on);
}

// The bytes read, 0 at the end of the connection, -1 on an error and -2
// when nothing is there yet.
long readSome(Native fd, char* buffer, size_t size) {
  const int n = recv(fd, buffer, static_cast<int>(size), 0);
  if (n >= 0) return n;
  return WSAGetLastError() == WSAEWOULDBLOCK ? -2 : -1;
}

// The bytes written, -1 on an error and -2 when the socket takes none now.
long writeSome(Native fd, const char* data, size_t size) {
  const int n = send(fd, data, static_cast<int>(size), 0);
  if (n >= 0) return n;
  return WSAGetLastError() == WSAEWOULDBLOCK ? -2 : -1;
}

// Whether the connection `fd` is still open: data waits or nothing yet.
bool stillOpen(Native fd) {
  char byte = 0;
  const int n = recv(fd, &byte, 1, MSG_PEEK);
  return n > 0 || (n < 0 && WSAGetLastError() == WSAEWOULDBLOCK);
}

int pollAll(PollEntry* entries, unsigned long count, int timeoutMs) {
  return WSAPoll(entries, count, timeoutMs);
}

bool interrupted() { return false; }

std::wstring wide(const std::string& text) {
  if (text.empty()) return {};
  const int length = MultiByteToWideChar(CP_UTF8, 0, text.data(),
                                         static_cast<int>(text.size()), nullptr, 0);
  std::wstring result(static_cast<size_t>(length), L'\0');
  MultiByteToWideChar(CP_UTF8, 0, text.data(), static_cast<int>(text.size()),
                      &result[0], length);
  return result;
}

void removeFile(const std::string& path) { DeleteFileW(wide(path).c_str()); }

std::string socketName() {
  std::random_device random;
  char name[64];
  std::snprintf(name, sizeof(name), "\\aud-vst3-%lu-%08x.sock",
                static_cast<unsigned long>(GetCurrentProcessId()), random());
  return name;
}
#else
using Native = int;
using PollEntry = pollfd;

void closeSocket(Native fd) { close(fd); }

void setNonBlocking(Native fd) {
  fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK);
  fcntl(fd, F_SETFD, FD_CLOEXEC);
}

long readSome(Native fd, char* buffer, size_t size) {
  for (;;) {
    const ssize_t n = read(fd, buffer, size);
    if (n >= 0) return static_cast<long>(n);
    if (errno == EINTR) continue;
    return errno == EAGAIN || errno == EWOULDBLOCK ? -2 : -1;
  }
}

long writeSome(Native fd, const char* data, size_t size) {
  for (;;) {
    const ssize_t n = write(fd, data, size);
    if (n >= 0) return static_cast<long>(n);
    if (errno == EINTR) continue;
    return errno == EAGAIN || errno == EWOULDBLOCK ? -2 : -1;
  }
}

bool stillOpen(Native fd) {
  char byte = 0;
  const ssize_t n = recv(fd, &byte, 1, MSG_PEEK | MSG_DONTWAIT);
  return n > 0 || (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK));
}

int pollAll(PollEntry* entries, unsigned long count, int timeoutMs) {
  return poll(entries, static_cast<nfds_t>(count), timeoutMs);
}

bool interrupted() { return errno == EINTR; }

void removeFile(const std::string& path) { unlink(path.c_str()); }

std::string socketName() {
  char name[64];
  std::snprintf(name, sizeof(name), "/aud-vst3-%d-%08x.sock", getpid(),
                arc4random());
  return name;
}

void noSigPipe(Native fd) {
  const int on = 1;
  setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, sizeof(on));
}
#endif

}  // namespace

// #############################################################################
// SocketServer

// .............................................................................
SocketServer::SocketServer(MessageHandler onMessage, StateHandler onState)
    : onMessage_(std::move(onMessage)), onState_(std::move(onState)) {}

// .............................................................................
SocketServer::~SocketServer() {
  stopping_ = true;
  wake();
  if (thread_.joinable()) thread_.join();
  for (const Handle fd : {connFd_, pendingFd_, listenFd_, wake_[0], wake_[1]}) {
    if (fd != kNone) closeSocket(static_cast<Native>(fd));
  }
  if (!path_.empty()) removeFile(path_);
#if _WIN32
  if (winsock_) WSACleanup();
#endif
}

// .............................................................................
bool SocketServer::start(const std::string& directory) {
#if _WIN32
  WSADATA data;
  if (WSAStartup(MAKEWORD(2, 2), &data) != 0) return false;
  winsock_ = true;
#endif
  path_ = directory + socketName();
  sockaddr_un address{};
  address.sun_family = AF_UNIX;
  if (path_.size() >= sizeof(address.sun_path)) return false;
  std::memcpy(address.sun_path, path_.c_str(), path_.size() + 1);
  const Native listener = socket(AF_UNIX, SOCK_STREAM, 0);
  if (listener == static_cast<Native>(kNone)) return false;
  listenFd_ = static_cast<Handle>(listener);
  removeFile(path_);
  if (bind(listener, reinterpret_cast<sockaddr*>(&address), sizeof(address)) != 0) {
    return false;
  }
#if !_WIN32
  if (chmod(path_.c_str(), 0600) != 0) return false;
#endif
  if (listen(listener, 2) != 0) return false;
#if _WIN32
  // Winsock has no pipe: the wake channel is a connection of the listening
  // socket to itself, made before the IPC thread accepts anything.
  const Native writer = socket(AF_UNIX, SOCK_STREAM, 0);
  if (writer == INVALID_SOCKET) return false;
  wake_[1] = static_cast<Handle>(writer);
  if (connect(writer, reinterpret_cast<sockaddr*>(&address), sizeof(address)) != 0) {
    return false;
  }
  const Native reader = ::accept(listener, nullptr, nullptr);
  if (reader == INVALID_SOCKET) return false;
  wake_[0] = static_cast<Handle>(reader);
  setNonBlocking(reader);
  setNonBlocking(writer);
  setNonBlocking(listener);
#else
  setNonBlocking(listener);
#endif
  return startThread();
}

#if !_WIN32
// .............................................................................
bool SocketServer::startPaired() { return startThread(); }

// .............................................................................
int SocketServer::connectPair() {
  int fds[2] = {-1, -1};
  if (socketpair(AF_UNIX, SOCK_STREAM, 0, fds) != 0) return -1;
  setNonBlocking(fds[0]);
  noSigPipe(fds[0]);
  // Not inherited by anything but the editor the caller starts with it.
  fcntl(fds[0], F_SETFD, FD_CLOEXEC);
  fcntl(fds[1], F_SETFD, FD_CLOEXEC);
  {
    std::lock_guard<std::mutex> lock(mutex_);
    if (pendingFd_ != kNone) close(pendingFd_);
    pendingFd_ = fds[0];
  }
  wake();
  return fds[1];
}
#endif

// .............................................................................
void SocketServer::send(const aud::Json& message, bool droppable) {
  std::string frame = frameOf(message);
  {
    std::lock_guard<std::mutex> lock(mutex_);
    // Only the editor's connection: one that replaced it may not be the
    // editor's, and a late message of the old one must not reach it.
    if (connection_ == 0 || authenticated_ != connection_) return;
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

// .............................................................................
void SocketServer::authenticate(uint64_t connection) {
  std::lock_guard<std::mutex> lock(mutex_);
  if (connection_ == connection) authenticated_ = connection;
}

// .............................................................................
void SocketServer::disconnect(uint64_t connection) {
  {
    std::lock_guard<std::mutex> lock(mutex_);
    if (connection_ != connection) return;
    disconnectRequested_ = connection;
  }
  wake();
}

bool SocketServer::startThread() {
#if !_WIN32
  int fds[2] = {-1, -1};
  if (pipe(fds) != 0) return false;
  wake_[0] = fds[0];
  wake_[1] = fds[1];
  setNonBlocking(wake_[0]);
  setNonBlocking(wake_[1]);
#endif
  thread_ = std::thread([this] { loop(); });
  return true;
}

void SocketServer::wake() {
  if (wake_[1] == kNone) return;
  const char byte = 1;
  (void)writeSome(static_cast<Native>(wake_[1]), &byte, 1);
}

void SocketServer::closeConnection() {
  if (connFd_ == kNone) return;
  closeSocket(static_cast<Native>(connFd_));
  connFd_ = kNone;
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

// [IPC thread] The plugin's end of a new pair replaces the connection: the
// plugin started a new editor.
void SocketServer::adopt(Handle fd) {
  closeConnection();
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

// A new connection replaces one that is not authenticated or already gone;
// while the editor's connection lives, a further one is refused.
void SocketServer::accept() {
  const Native fd = ::accept(static_cast<Native>(listenFd_), nullptr, nullptr);
  if (fd == static_cast<Native>(kNone)) return;
  setNonBlocking(fd);
#if !_WIN32
  noSigPipe(fd);
#endif
  if (connFd_ != kNone) {
    bool authenticated = false;
    {
      std::lock_guard<std::mutex> lock(mutex_);
      authenticated = authenticated_ != 0 && authenticated_ == connection_;
    }
    if (authenticated && stillOpen(static_cast<Native>(connFd_))) {
      closeSocket(fd);
      return;
    }
    closeConnection();
  }
  connFd_ = static_cast<Handle>(fd);
  const uint64_t connection = ++lastConnection_;
  {
    std::lock_guard<std::mutex> lock(mutex_);
    connection_ = connection;
    authenticated_ = 0;
    disconnectRequested_ = 0;
  }
  onState_(true, connection);
}

bool SocketServer::readFrom(Handle fd) {
  char buffer[65536];
  bool open = true;
  for (;;) {
    const long n = readSome(static_cast<Native>(fd), buffer, sizeof(buffer));
    if (n > 0) {
      inbox_.append(buffer, static_cast<size_t>(n));
      continue;
    }
    if (n == -2) break;
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
    if (!wantWrite && connFd_ != kNone) {
      std::lock_guard<std::mutex> lock(mutex_);
      wantWrite = !outbox_.empty();
    }
    // The entries in use come first: the wake channel, the listening socket
    // if there is one, the connection if there is one.
    PollEntry fds[3] = {};
    unsigned long count = 0;
    fds[count++] = {static_cast<Native>(wake_[0]), POLLIN, 0};
    const int listenAt = listenFd_ != kNone ? static_cast<int>(count) : -1;
    if (listenAt >= 0) fds[count++] = {static_cast<Native>(listenFd_), POLLIN, 0};
    const int connAt = connFd_ != kNone ? static_cast<int>(count) : -1;
    if (connAt >= 0) {
      fds[count++] = {static_cast<Native>(connFd_),
                      static_cast<short>(POLLIN | (wantWrite ? POLLOUT : 0)), 0};
    }
    if (pollAll(fds, count, 1000) < 0 && !interrupted()) break;
    if (stopping_) break;
    if (fds[0].revents & POLLIN) {
      char drain[256];
      while (readSome(static_cast<Native>(wake_[0]), drain, sizeof(drain)) > 0) {
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
    {
      Handle pending = kNone;
      {
        std::lock_guard<std::mutex> lock(mutex_);
        std::swap(pending, pendingFd_);
      }
      if (pending != kNone) {
        adopt(pending);
        continue;
      }
    }
    if (listenAt >= 0 && (fds[listenAt].revents & POLLIN)) {
      accept();
      continue;
    }
    if (connFd_ == kNone) continue;
    if (connAt >= 0 && (fds[connAt].revents & (POLLIN | POLLHUP | POLLERR))) {
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
      const long n = writeSome(static_cast<Native>(connFd_), writing_.data() + written_,
                               writing_.size() - written_);
      if (n > 0) {
        written_ += static_cast<size_t>(n);
        if (written_ == writing_.size()) {
          writing_.clear();
          written_ = 0;
        }
        continue;
      }
      if (n == -2) break;
      closeConnection();
      break;
    }
  }
}

}  // namespace aud_vst3
