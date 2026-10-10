// @license
// Copyright (c) Audanika. All Rights Reserved.
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

// The plugin's end of the surface channel of aud_vst3_mach.h (ticket 24,
// variant A): registers a receive port under a name of its own, keeps the
// IOSurfaces of the editor's pool of every instance and hands every frame
// to the host's UI thread.
//
// Every surface the editor sends a frame in comes back to it: a frame the
// plugin cannot show (an unknown pool, a missing surface) is released at
// once, and a release the editor's port does not take now is sent again
// later, so the editor's pool never runs dry.

#ifndef AUD_VST3_SURFACES_HPP
#define AUD_VST3_SURFACES_HPP

#include <IOSurface/IOSurfaceRef.h>
#include <dispatch/dispatch.h>
#include <mach/mach.h>

#include <cstdint>
#include <functional>
#include <map>
#include <mutex>
#include <string>
#include <vector>

#include "aud_vst3_mach.h"

namespace aud_vst3 {

struct SurfaceFrame {
  IOSurfaceRef surface = nullptr;  // retained for the handler
  uint32_t instance = 0;
  uint32_t index = 0;
  uint32_t generation = 0;
  uint64_t frame = 0;
  int64_t captured = 0;  // mach time ns
  double scale = 1;
};

class SurfaceChannel {
 public:
  // [UI thread] A frame to show; the handler releases frame.surface.
  using FrameHandler = std::function<void(const SurfaceFrame& frame)>;

  explicit SurfaceChannel(FrameHandler onFrame);
  ~SurfaceChannel();

  SurfaceChannel(const SurfaceChannel&) = delete;
  SurfaceChannel& operator=(const SurfaceChannel&) = delete;

  // Registers the port under a new name; false when bootstrap refuses it.
  bool start();

  // The name the editor looks up.
  const std::string& name() const { return name_; }

  // [any thread] Hands surface `index` of `instance` back to the editor.
  void release(uint32_t instance, uint32_t index, uint32_t generation);

  // Drops the surfaces of `instance`.
  void drop(uint32_t instance);

  // Drops the editor's port and every surface, for a new editor process.
  void reset();

 private:
  void receive();
  // With mutex_ held: sends one release; false when the port refused it.
  bool sendRelease(uint32_t instance, uint32_t index, uint32_t generation);
  // With mutex_ held: sends the releases the port refused before.
  void flushPending();

  FrameHandler onFrame_;
  std::string name_;
  mach_port_t port_ = MACH_PORT_NULL;
  dispatch_queue_t queue_ = nullptr;
  dispatch_source_t source_ = nullptr;

  struct Pool {
    IOSurfaceRef surfaces[AUD_MACH_POOL_SIZE] = {};
    uint32_t generation = 0;
    double scale = 1;
  };

  static void clear(Pool& pool);

  struct Release {
    uint32_t instance;
    uint32_t index;
    uint32_t generation;
  };

  std::mutex mutex_;
  mach_port_t editorPort_ = MACH_PORT_NULL;
  std::map<uint32_t, Pool> pools_;
  std::vector<Release> pending_;
  // Signalled by the source's cancel handler, which owns the receive right.
  dispatch_semaphore_t cancelled_ = nullptr;
};

}  // namespace aud_vst3

#endif  // AUD_VST3_SURFACES_HPP
