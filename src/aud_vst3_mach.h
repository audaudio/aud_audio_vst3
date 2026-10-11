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

// #############################################################################
// The ids of the messages: "AD" and their number.
#define AUD_MACH_HELLO 0x41440001
#define AUD_MACH_SURFACE 0x41440002
#define AUD_MACH_FRAME 0x41440003
#define AUD_MACH_RELEASE 0x41440004

// #############################################################################
// The surfaces of one pool.
#define AUD_MACH_POOL_SIZE 3

// #############################################################################
// Editor to plugin: the send right of the editor's receive port.
typedef struct AudMachHello {
  // ...........................................................................
  // A complex message with one port descriptor: the send right.
  mach_msg_header_t header;
  mach_msg_body_t body;
  mach_msg_port_descriptor_t port;

  // ...........................................................................
  // The editor's process id.
  int32_t pid;
} AudMachHello;

// #############################################################################
// Editor to plugin: one surface of the pool of plugin instance `instance`.
// A new pool (a new size or scale) raises the generation; frames of older
// pools are dropped.
typedef struct AudMachSurface {
  // ...........................................................................
  // A complex message with one port descriptor: the send right of the
  // surface's Mach port.
  mach_msg_header_t header;
  mach_msg_body_t body;
  mach_msg_port_descriptor_t port;

  // ...........................................................................
  // The plugin instance, the surface's index in the pool and the pool's
  // generation.
  uint32_t instance;
  uint32_t index;
  uint32_t generation;

  // ...........................................................................
  // The size of the surface in pixels, and its pixels per point.
  uint32_t width;
  uint32_t height;
  double scale;
} AudMachSurface;

// #############################################################################
// Editor to plugin: surface `index` of instance `instance` holds frame
// `frame`, copied at `captured` (mach time in nanoseconds).
typedef struct AudMachFrame {
  // ...........................................................................
  // A simple message.
  mach_msg_header_t header;

  // ...........................................................................
  // The plugin instance, the surface's index in the pool and the pool's
  // generation.
  uint32_t instance;
  uint32_t index;
  uint32_t generation;

  // ...........................................................................
  // The number of the frame, and when the editor copied it.
  uint64_t frame;
  int64_t captured;
} AudMachFrame;

// #############################################################################
// Plugin to editor: surface `index` of instance `instance` is no longer
// shown.
typedef struct AudMachRelease {
  // ...........................................................................
  // A simple message.
  mach_msg_header_t header;

  // ...........................................................................
  // The plugin instance, the surface's index in the pool and the pool's
  // generation.
  uint32_t instance;
  uint32_t index;
  uint32_t generation;
} AudMachRelease;

// #############################################################################
// The largest message, with room for the receive trailer.
typedef union AudMachBuffer {
  // ...........................................................................
  // The messages.
  AudMachHello hello;
  AudMachSurface surface;
  AudMachFrame frame;
  AudMachRelease release;

  // ...........................................................................
  // The bytes a receive may fill.
  uint8_t bytes[256];
} AudMachBuffer;

#endif  // AUD_VST3_MACH_H
