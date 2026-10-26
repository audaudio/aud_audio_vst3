// @license
// Copyright (c) Audanika. All Rights Reserved.
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

// The identity of a plugin build (ticket 37). scripts/build-plugin.js
// defines it from the plugin.json of the app that builds the plugin; the
// defaults below are those of the package's example plugin and serve the
// native tests.
//
// - AUD_VST3_NAME, AUD_VST3_VENDOR, AUD_VST3_URL, AUD_VST3_EMAIL: the class
//   and its vendor as the DAW lists them
// - AUD_VST3_VERSION: the version of the class
// - AUD_VST3_SUBCATEGORIES: e.g. "Instrument|Synth"
// - AUD_VST3_CID0 to AUD_VST3_CID3: the class id, four 32-bit words that
//   never change once a DAW project uses the plugin
//
// The log's subsystem is the bundle id, as AUD_PLUGIN_LOG_SUBSYSTEM of
// aud_audio_plugin (scripts/build-plugin.js).

#ifndef AUD_VST3_CONFIG_HPP
#define AUD_VST3_CONFIG_HPP

#include "aud_plugin_config.hpp"

#ifndef AUD_VST3_NAME
#define AUD_VST3_NAME "Aud Example"
#endif

#ifndef AUD_VST3_VENDOR
#define AUD_VST3_VENDOR "Audanika"
#endif

#ifndef AUD_VST3_URL
#define AUD_VST3_URL "https://github.com/audaudio/aud_audio_vst3"
#endif

#ifndef AUD_VST3_EMAIL
#define AUD_VST3_EMAIL "mailto:info@audanika.com"
#endif

#ifndef AUD_VST3_VERSION
#define AUD_VST3_VERSION "0.2.0"
#endif

#ifndef AUD_VST3_SUBCATEGORIES
#define AUD_VST3_SUBCATEGORIES "Instrument|Synth"
#endif

#ifndef AUD_VST3_CID0
#define AUD_VST3_CID0 0x41554433u  // "AUD3"
#define AUD_VST3_CID1 0x4558414Du  // "EXAM"
#define AUD_VST3_CID2 0x504C4500u  // "PLE"
#define AUD_VST3_CID3 0x00000001u
#endif

// #############################################################################
// The realtime path of the plugin carries Clang's nonblocking effect in a
// RealtimeSanitizer build (AUD_PLUGIN_RTSAN), as that of aud_audio_plugin.
#define AUD_VST3_NONBLOCKING AUD_PLUGIN_NONBLOCKING

#endif  // AUD_VST3_CONFIG_HPP
