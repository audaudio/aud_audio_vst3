// @license
// Copyright (c) Audanika. All Rights Reserved.
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

#include "aud_vst3_surfaces.hpp"

#import <Foundation/Foundation.h>
#include <IOSurface/IOSurface.h>
#include <bootstrap.h>
#include <servers/bootstrap.h>
#include <unistd.h>

#include <cstdio>
#include <cstring>

namespace aud_vst3 {

namespace {

// Whether a message of at least `size` bytes carries exactly one port
// descriptor with a send right: what the editor sends with
// MACH_MSG_TYPE_MAKE_SEND, COPY_SEND or MOVE_SEND arrives as PORT_SEND.
bool carriesSendRight(const mach_msg_header_t& header, size_t size,
                      const mach_msg_body_t& body,
                      const mach_msg_port_descriptor_t& port) {
  return (header.msgh_bits & MACH_MSGH_BITS_COMPLEX) != 0 &&
         header.msgh_size >= size && body.msgh_descriptor_count == 1 &&
         port.type == MACH_MSG_PORT_DESCRIPTOR &&
         port.disposition == MACH_MSG_TYPE_PORT_SEND;
}

// Whether a received message is what its id promises. Every process that
// finds the port's name can send to it: a message taken by its id alone
// would make the plugin keep or deallocate a port name of the sender's
// choice. The editor sends no reply port, so a valid message carries no
// right besides the one of its descriptor.
bool wellFormed(const AudMachBuffer& buffer) {
  const mach_msg_header_t& header = buffer.frame.header;
  if (MACH_MSGH_BITS_REMOTE(header.msgh_bits) != 0) return false;
  switch (header.msgh_id) {
    case AUD_MACH_HELLO:
      return carriesSendRight(header, sizeof(AudMachHello), buffer.hello.body,
                              buffer.hello.port);
    case AUD_MACH_SURFACE:
      return carriesSendRight(header, sizeof(AudMachSurface),
                              buffer.surface.body, buffer.surface.port);
    case AUD_MACH_FRAME:
      return (header.msgh_bits & MACH_MSGH_BITS_COMPLEX) == 0 &&
             header.msgh_size >= sizeof(AudMachFrame);
    default:
      return false;
  }
}

}  // namespace

// #############################################################################
// SurfaceChannel

// .............................................................................
SurfaceChannel::SurfaceChannel(FrameHandler onFrame)
    : onFrame_(std::move(onFrame)) {}

// .............................................................................
SurfaceChannel::~SurfaceChannel() {
  if (source_ != nullptr) {
    // The cancel handler destroys the receive right: libdispatch allows it
    // only once the source is cancelled.
    dispatch_source_cancel(source_);
    dispatch_semaphore_wait(cancelled_, DISPATCH_TIME_FOREVER);
    cancelled_ = nil;
    source_ = nullptr;
    port_ = MACH_PORT_NULL;
  } else if (port_ != MACH_PORT_NULL) {
    mach_port_mod_refs(mach_task_self(), port_, MACH_PORT_RIGHT_RECEIVE, -1);
    port_ = MACH_PORT_NULL;
  }
  reset();
}

// .............................................................................
bool SurfaceChannel::start() {
  char name[128];
  std::snprintf(name, sizeof(name), "io.audaudio.vst3.%d.%08x%08x", getpid(),
                arc4random(), arc4random());
  name_ = name;
  if (bootstrap_check_in(bootstrap_port, name_.c_str(), &port_) !=
      KERN_SUCCESS) {
    return false;
  }
  // Room for the frames of several editors: the default queue holds 5.
  mach_port_limits_t limits{};
  limits.mpl_qlimit = 64;
  mach_port_set_attributes(mach_task_self(), port_, MACH_PORT_LIMITS_INFO,
                           reinterpret_cast<mach_port_info_t>(&limits),
                           MACH_PORT_LIMITS_INFO_COUNT);
  queue_ = dispatch_queue_create("aud.vst3.surfaces", DISPATCH_QUEUE_SERIAL);
  source_ = dispatch_source_create(DISPATCH_SOURCE_TYPE_MACH_RECV, port_, 0,
                                   queue_);
  cancelled_ = dispatch_semaphore_create(0);
  SurfaceChannel* self = this;
  const mach_port_t port = port_;
  dispatch_semaphore_t cancelled = cancelled_;
  dispatch_source_set_event_handler(source_, ^{
    self->receive();
  });
  dispatch_source_set_cancel_handler(source_, ^{
    mach_port_mod_refs(mach_task_self(), port, MACH_PORT_RIGHT_RECEIVE, -1);
    dispatch_semaphore_signal(cancelled);
  });
  dispatch_resume(source_);
  return true;
}

void SurfaceChannel::receive() {
  AudMachBuffer buffer;
  std::memset(&buffer, 0, sizeof(buffer));
  mach_msg_header_t* header = &buffer.frame.header;
  if (mach_msg(header, MACH_RCV_MSG | MACH_RCV_TIMEOUT, 0, sizeof(buffer),
               port_, 0, MACH_PORT_NULL) != KERN_SUCCESS) {
    return;
  }
  if (!wellFormed(buffer)) {
    // Goes with every right it carries.
    mach_msg_destroy(header);
    return;
  }
  switch (header->msgh_id) {
    case AUD_MACH_HELLO: {
      std::lock_guard<std::mutex> lock(mutex_);
      if (editorPort_ != MACH_PORT_NULL) {
        mach_port_deallocate(mach_task_self(), editorPort_);
      }
      editorPort_ = buffer.hello.port.name;
      return;  // the right is kept, not destroyed with the message
    }
    case AUD_MACH_SURFACE: {
      IOSurfaceRef surface = IOSurfaceLookupFromMachPort(buffer.surface.port.name);
      mach_port_deallocate(mach_task_self(), buffer.surface.port.name);
      if (surface == nullptr || buffer.surface.index >= AUD_MACH_POOL_SIZE) {
        if (surface != nullptr) CFRelease(surface);
        return;
      }
      std::lock_guard<std::mutex> lock(mutex_);
      Pool& pool = pools_[buffer.surface.instance];
      if (buffer.surface.generation != pool.generation) {
        clear(pool);
        pool.generation = buffer.surface.generation;
      }
      IOSurfaceRef& slot = pool.surfaces[buffer.surface.index];
      if (slot != nullptr) CFRelease(slot);
      slot = surface;
      pool.scale = buffer.surface.scale;
      return;
    }
    case AUD_MACH_FRAME: {
      SurfaceFrame frame;
      {
        std::lock_guard<std::mutex> lock(mutex_);
        flushPending();
        const auto it = pools_.find(buffer.frame.instance);
        if (it == pools_.end() || buffer.frame.generation != it->second.generation ||
            buffer.frame.index >= AUD_MACH_POOL_SIZE ||
            it->second.surfaces[buffer.frame.index] == nullptr) {
          // Not shown, so handed back at once: the editor waits for it.
          if (!sendRelease(buffer.frame.instance, buffer.frame.index,
                           buffer.frame.generation)) {
            pending_.push_back({buffer.frame.instance, buffer.frame.index,
                                buffer.frame.generation});
          }
          return;
        }
        frame.surface = it->second.surfaces[buffer.frame.index];
        CFRetain(frame.surface);
        frame.scale = it->second.scale;
      }
      frame.instance = buffer.frame.instance;
      frame.index = buffer.frame.index;
      frame.generation = buffer.frame.generation;
      frame.frame = buffer.frame.frame;
      frame.captured = buffer.frame.captured;
      FrameHandler handler = onFrame_;
      dispatch_async(dispatch_get_main_queue(), ^{
        handler(frame);
      });
      return;
    }
  }
}

// .............................................................................
void SurfaceChannel::release(uint32_t instance, uint32_t index,
                             uint32_t generation) {
  std::lock_guard<std::mutex> lock(mutex_);
  flushPending();
  if (!sendRelease(instance, index, generation)) {
    pending_.push_back({instance, index, generation});
  }
}

void SurfaceChannel::flushPending() {
  std::vector<Release> pending;
  pending.swap(pending_);
  for (const Release& r : pending) {
    if (!sendRelease(r.instance, r.index, r.generation)) pending_.push_back(r);
  }
}

bool SurfaceChannel::sendRelease(uint32_t instance, uint32_t index,
                                 uint32_t generation) {
  // Without an editor there is nobody to hand it back to, and nothing lost.
  if (editorPort_ == MACH_PORT_NULL) return true;
  AudMachRelease message;
  std::memset(&message, 0, sizeof(message));
  message.header.msgh_bits = MACH_MSGH_BITS(MACH_MSG_TYPE_COPY_SEND, 0);
  message.header.msgh_size = sizeof(message);
  message.header.msgh_remote_port = editorPort_;
  message.header.msgh_id = AUD_MACH_RELEASE;
  message.instance = instance;
  message.index = index;
  message.generation = generation;
  // Never waits for a hung editor: the queue of its port is the buffer,
  // and a release it refuses now is sent again with the next one.
  return mach_msg(&message.header, MACH_SEND_MSG | MACH_SEND_TIMEOUT,
                  sizeof(message), 0, MACH_PORT_NULL, 0, MACH_PORT_NULL) !=
         MACH_SEND_TIMED_OUT;
}

void SurfaceChannel::clear(Pool& pool) {
  for (auto& surface : pool.surfaces) {
    if (surface != nullptr) CFRelease(surface);
    surface = nullptr;
  }
}

// .............................................................................
void SurfaceChannel::drop(uint32_t instance) {
  std::lock_guard<std::mutex> lock(mutex_);
  const auto it = pools_.find(instance);
  if (it == pools_.end()) return;
  clear(it->second);
  pools_.erase(it);
}

// .............................................................................
void SurfaceChannel::reset() {
  std::lock_guard<std::mutex> lock(mutex_);
  pending_.clear();
  if (editorPort_ != MACH_PORT_NULL) {
    mach_port_deallocate(mach_task_self(), editorPort_);
    editorPort_ = MACH_PORT_NULL;
  }
  for (auto& entry : pools_) clear(entry.second);
  pools_.clear();
}

}  // namespace aud_vst3
