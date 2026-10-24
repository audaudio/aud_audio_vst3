// @license
// Copyright (c) Audanika. All Rights Reserved.
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

// Where the plugin is and what it finds around it (ticket 37; Windows in
// ticket 38): its bundle, resolved through the link that places it in the
// DAW's plug-in folder, its resources, the content of the app it ships in,
// and the system's log, which replaces the log files of the spike - a
// plugin writes no file of its own. Paths are UTF-8.
//
// aud_vst3_bundle.cpp holds what every platform shares;
// aud_vst3_bundle_mac.mm and aud_vst3_bundle_win.cpp what differs.

#ifndef AUD_VST3_BUNDLE_HPP
#define AUD_VST3_BUNDLE_HPP

#include <string>
#include <vector>

namespace aud_vst3 {

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

// #############################################################################
// The path a location of plugin.json names for the bundle at `bundle`:
// `containing-app:<path>` inside the .app that holds the bundle,
// `containing-folder:<path>` inside the folder that holds it,
// `app:<bundle id>:<path>` inside the installed app with that id (macOS),
// `bundle:<path>` inside the bundle; empty for none.
std::string locate(const std::string& location, const std::string& bundle);

// #############################################################################
// The first of `locations` (plugin.json `content`) that is a directory, for
// the bundle at `bundle` (locate); empty when none exists.
std::string contentDirectory(const std::vector<std::string>& locations,
                             const std::string& bundle);

// #############################################################################
// The .app that holds `path`, e.g. /Applications/A.app for
// /Applications/A.app/Contents/PlugIns/A.vst3; empty when none does.
std::string containingApp(const std::string& path);

// #############################################################################
// The folder that holds `path`, e.g. C:\App for C:\App\A.vst3; empty for a
// path without a folder.
std::string containingFolder(const std::string& path);

// #############################################################################
// `path` and `relative`, whose parts are separated by '/', joined with the
// separator of the platform.
std::string joinPath(const std::string& path, const std::string& relative);

// #############################################################################
// Whether `path` is a directory, or a file.
bool isDirectory(const std::string& path);
bool isFile(const std::string& path);

// #############################################################################
// Logs `message` to the system's log under the bundle id of the plugin, and
// to the file AUD_VST3_LOG names when a test sets it; the realtime thread
// never calls it.
void logInfo(const std::string& message);
void logError(const std::string& message);

// #############################################################################
// The file AUD_VST3_LOG names, where a test wants the plugin's and the
// editor's lines; empty without it.
std::string logFile();

// #############################################################################
// Per platform

// .............................................................................
// The installed app with the bundle id `identifier`; empty when there is
// none or the platform has no such lookup (Windows).
std::string appWithIdentifier(const std::string& identifier);

// .............................................................................
// Writes `message` to the system's log: the unified log on macOS, the
// debugger's output on Windows.
void systemLog(bool error, const std::string& message);

// .............................................................................
// The id of this process.
long processId();

}  // namespace aud_vst3

#endif  // AUD_VST3_BUNDLE_HPP
