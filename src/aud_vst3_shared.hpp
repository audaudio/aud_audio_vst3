// @license
// Copyright (c) Audanika. All Rights Reserved.
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

// The shared core of the plugin shells, aud_audio_plugin (plugin-010), as
// the VST3 shell uses it: the engine over the headless host, the settings
// and the state, the node packages of the build, the host transport, MIDI
// events and the content lookup. Its names belong to the shell's namespace
// as well, so that the shell's code names them as its own.

#ifndef AUD_VST3_SHARED_HPP
#define AUD_VST3_SHARED_HPP

#include "aud_plugin_bundle.hpp"
#include "aud_plugin_engine.hpp"
#include "aud_plugin_midi.hpp"
#include "aud_plugin_packages.hpp"
#include "aud_plugin_settings.hpp"
#include "aud_plugin_transport.hpp"

namespace aud_vst3 {

using namespace aud_plugin;

}  // namespace aud_vst3

#endif  // AUD_VST3_SHARED_HPP
