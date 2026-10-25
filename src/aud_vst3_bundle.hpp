// @license
// Copyright (c) Audanika. All Rights Reserved.
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

// Where the plugin is (ticket 37; Windows in ticket 38): its .vst3 bundle,
// resolved through the link that places it in the DAW's plug-in folder,
// and its configuration. The content of the app it ships in, the system's
// log and the paths around it come from aud_audio_plugin
// (aud_plugin_bundle.hpp).

#ifndef AUD_VST3_BUNDLE_HPP
#define AUD_VST3_BUNDLE_HPP

#include <string>

#include "aud_vst3_shared.hpp"

namespace aud_vst3 {

// #############################################################################
// The .vst3 bundle of the binary at `binary`:
// <bundle>.vst3/Contents/MacOS/<binary> on macOS,
// <bundle>.vst3\Contents\x86_64-win\<binary>.vst3 on Windows; a plugin of
// one file (Windows) is its own bundle.
std::string bundleOf(const std::string& binary);

// #############################################################################
// The path of the .vst3 bundle whose binary holds this code, as the DAW
// loaded it; empty when the system does not know it.
std::string bundlePath();

// #############################################################################
// The bundle with every link resolved: inside the app that ships the
// plugin when the DAW loads it through a link.
std::string resolvedBundlePath();

// #############################################################################
// The directory of the plugin's configuration: Contents/Resources/aud_plugin
// of the resolved bundle.
std::string settingsDirectory();

}  // namespace aud_vst3

#endif  // AUD_VST3_BUNDLE_HPP
