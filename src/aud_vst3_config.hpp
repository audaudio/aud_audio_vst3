// @license
// Copyright (c) Audanika. All Rights Reserved.
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

// The build configuration of the spike plugin (ticket 24, S0-plugin-ui).
// scripts/build-plugin.js builds one bundle per variant and flavor:
//
// - AUD_VST3_VARIANT: the editor. 'A' Flutter in a separate process,
//   embedded through shared IOSurfaces, one process per open editor; 'S'
//   the same with one process for every instance of the build in the DAW
//   process; 'F' the editor process in a window that follows the editor
//   rectangle (A's comparison); 'B'
//   Flutter in the DAW process; 'C' a native AppKit view; 'D' no view,
//   the host's generic one.
// - AUD_VST3_FLAVOR: 1 or 2, the engine flavor of the two-engine test.
//   Flavor 2 builds against another graph version and changes the layout
//   of an inline type (aud_vst3_skew.hpp).
// - AUD_VST3_NO_HYGIENE: the control build of that test - fixed
//   Objective-C class names and default symbol visibility.

#ifndef AUD_VST3_CONFIG_HPP
#define AUD_VST3_CONFIG_HPP

#ifndef AUD_VST3_VARIANT
#define AUD_VST3_VARIANT 'D'
#endif

#ifndef AUD_VST3_FLAVOR
#define AUD_VST3_FLAVOR 1
#endif

#ifndef AUD_VST3_VERSION
#define AUD_VST3_VERSION "0.1.0"
#endif

// With AUD_VST3_RTSAN the realtime path of the plugin carries Clang's
// nonblocking effect, so that RealtimeSanitizer checks what it calls.
#if AUD_VST3_RTSAN && defined(__clang__)
#define AUD_VST3_NONBLOCKING [[clang::nonblocking]]
#else
#define AUD_VST3_NONBLOCKING
#endif

namespace aud_vst3 {

// The editor variant of this build.
constexpr char kVariant = AUD_VST3_VARIANT;

// The engine flavor of this build.
constexpr int kFlavor = AUD_VST3_FLAVOR;

#ifdef AUD_VST3_NO_HYGIENE
constexpr bool kHygiene = false;
#else
constexpr bool kHygiene = true;
#endif

}  // namespace aud_vst3

#endif  // AUD_VST3_CONFIG_HPP
