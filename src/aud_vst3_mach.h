// @license
// Copyright (c) Audanika. All Rights Reserved.
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

// The surface channel between the plugin's view and its editor process
// (ticket 24, variant A). The shell protocol runs over the Unix socket; the
// IOSurfaces the editor renders into, and the frames shown in them, run
// over Mach messages, because only Mach messages carry the surfaces' ports.
//
// The plugin registers a receive port under a name of its own with
// bootstrap_check_in and passes the name to the editor, which looks it up;
// one editor process may serve several plugin instances, so every surface
// message names its instance.
// The editor sends AUD_MACH_HELLO with the send right of its own receive
// port, then AUD_MACH_SURFACE for each surface of a pool and AUD_MACH_FRAME
// for every frame it copied into one. The plugin shows the frame as layer
// contents and answers AUD_MACH_RELEASE for the surface it stopped showing.
// Included by C++ (the plugin) and Objective-C (the editor's runner).

#ifndef AUD_VST3_MACH_H
#define AUD_VST3_MACH_H

#include <mach/mach.h>
#include <stdint.h>

#define AUD_MACH_HELLO 0x41440001
#define AUD_MACH_SURFACE 0x41440002
#define AUD_MACH_FRAME 0x41440003
#define AUD_MACH_RELEASE 0x41440004

// The surfaces of one pool.
#define AUD_MACH_POOL_SIZE 3

// Editor to plugin: the send right of the editor's receive port.
typedef struct AudMachHello {
  mach_msg_header_t header;
  mach_msg_body_t body;
  mach_msg_port_descriptor_t port;
  int32_t pid;
} AudMachHello;

// Editor to plugin: one surface of the pool of plugin instance `instance`.
// A new pool (a new size or scale) raises the generation; frames of older
// pools are dropped.
typedef struct AudMachSurface {
  mach_msg_header_t header;
  mach_msg_body_t body;
  mach_msg_port_descriptor_t port;
  uint32_t instance;
  uint32_t index;
  uint32_t generation;
  uint32_t width;   // pixels
  uint32_t height;  // pixels
  double scale;     // pixels per point
} AudMachSurface;

// Editor to plugin: surface `index` of instance `instance` holds frame
// `frame`, copied at `captured` (mach time in nanoseconds).
typedef struct AudMachFrame {
  mach_msg_header_t header;
  uint32_t instance;
  uint32_t index;
  uint32_t generation;
  uint64_t frame;
  int64_t captured;
} AudMachFrame;

// Plugin to editor: surface `index` of instance `instance` is no longer
// shown.
typedef struct AudMachRelease {
  mach_msg_header_t header;
  uint32_t instance;
  uint32_t index;
  uint32_t generation;
} AudMachRelease;

// The largest message, with room for the receive trailer.
typedef union AudMachBuffer {
  AudMachHello hello;
  AudMachSurface surface;
  AudMachFrame frame;
  AudMachRelease release;
  uint8_t bytes[256];
} AudMachBuffer;

#endif  // AUD_VST3_MACH_H
