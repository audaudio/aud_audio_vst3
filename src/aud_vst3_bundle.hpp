// @license
// Copyright (c) Audanika. All Rights Reserved.
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

// Where the plugin is and what it finds around it (ticket 37): its bundle,
// resolved through the link that "Activate the plugin" places in the DAW's
// plug-in folder, its resources, the content of the app it ships in, and
// the unified log, which replaces the log files of the spike - a plugin
// writes no file of its own.

#ifndef AUD_VST3_BUNDLE_HPP
#define AUD_VST3_BUNDLE_HPP

#include <string>
#include <vector>

namespace aud_vst3 {

// #############################################################################
// The path of the .vst3 bundle whose binary holds this code, as the DAW
// loaded it; empty when dladdr does not know it.
std::string bundlePath();

// #############################################################################
// The bundle with every link resolved: inside the app that ships the
// plugin when the DAW loads it through a link.
std::string resolvedBundlePath();

// #############################################################################
// The directory of the plugin's configuration: Contents/Resources/aud_plugin
// of the resolved bundle.
std::string settingsDirectory();

// #############################################################################
// The first of `locations` (plugin.json `content`) that is a directory, for
// the bundle at `bundle`: `containing-app:<path>` inside the .app that holds
// the bundle, `app:<bundle id>:<path>` inside the installed app with that
// id, `bundle:<path>` inside the bundle; empty when none exists.
std::string contentDirectory(const std::vector<std::string>& locations,
                             const std::string& bundle);

// #############################################################################
// The .app that holds `path`, e.g. /Applications/A.app for
// /Applications/A.app/Contents/PlugIns/A.vst3; empty when none does.
std::string containingApp(const std::string& path);

// #############################################################################
// Logs `message` to the unified log under the subsystem of the plugin; the
// realtime thread never calls it.
void logInfo(const std::string& message);
void logError(const std::string& message);

}  // namespace aud_vst3

#endif  // AUD_VST3_BUNDLE_HPP
