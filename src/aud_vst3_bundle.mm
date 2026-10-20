// @license
// Copyright (c) Audanika. All Rights Reserved.
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

#include "aud_vst3_bundle.hpp"

#import <AppKit/AppKit.h>
#include <dlfcn.h>
#include <limits.h>
#include <os/log.h>
#include <stdlib.h>
#include <sys/stat.h>

#include "aud_vst3_config.hpp"

namespace aud_vst3 {

namespace {

bool isDirectory(const std::string& path) {
  struct stat info {};
  return !path.empty() && stat(path.c_str(), &info) == 0 &&
         S_ISDIR(info.st_mode);
}

bool startsWith(const std::string& text, const std::string& prefix) {
  return text.compare(0, prefix.size(), prefix) == 0;
}

os_log_t pluginLog() {
  static os_log_t log = os_log_create(AUD_VST3_BUNDLE_ID, "plugin");
  return log;
}

// The installed app with `identifier`, or empty.
std::string appWithIdentifier(const std::string& identifier) {
  @autoreleasepool {
    NSString* id = [NSString stringWithUTF8String:identifier.c_str()];
    NSURL* url = [[NSWorkspace sharedWorkspace]
        URLForApplicationWithBundleIdentifier:id];
    return url != nil ? std::string(url.path.UTF8String) : std::string();
  }
}

}  // namespace

// #############################################################################
std::string bundlePath() {
  Dl_info info{};
  if (dladdr(reinterpret_cast<const void*>(&bundlePath), &info) == 0 ||
      info.dli_fname == nullptr) {
    return {};
  }
  // <bundle>.vst3/Contents/MacOS/<binary>
  std::string path = info.dli_fname;
  for (int i = 0; i < 3; ++i) path = path.substr(0, path.rfind('/'));
  return path;
}

// #############################################################################
std::string resolvedBundlePath() {
  const std::string path = bundlePath();
  char resolved[PATH_MAX];
  if (path.empty() || realpath(path.c_str(), resolved) == nullptr) return path;
  return resolved;
}

// #############################################################################
std::string settingsDirectory() {
  return resolvedBundlePath() + "/Contents/Resources/aud_plugin";
}

// #############################################################################
std::string containingApp(const std::string& path) {
  // The outermost .app wins: a helper app inside a plugin inside an app
  // belongs to the app.
  const size_t at = path.find(".app/");
  if (at != std::string::npos) return path.substr(0, at + 4);
  if (path.size() >= 4 && path.compare(path.size() - 4, 4, ".app") == 0) {
    return path;
  }
  return {};
}

// #############################################################################
std::string contentDirectory(const std::vector<std::string>& locations,
                             const std::string& bundle) {
  for (const std::string& location : locations) {
    std::string candidate;
    if (startsWith(location, "containing-app:")) {
      const std::string app = containingApp(bundle);
      if (!app.empty()) candidate = app + "/" + location.substr(15);
    } else if (startsWith(location, "app:")) {
      const size_t colon = location.find(':', 4);
      if (colon != std::string::npos) {
        const std::string app =
            appWithIdentifier(location.substr(4, colon - 4));
        if (!app.empty()) candidate = app + "/" + location.substr(colon + 1);
      }
    } else if (startsWith(location, "bundle:")) {
      candidate = bundle + "/" + location.substr(7);
    }
    if (isDirectory(candidate)) return candidate;
  }
  return {};
}

// #############################################################################
void logInfo(const std::string& message) {
  os_log_info(pluginLog(), "%{public}s", message.c_str());
}

// #############################################################################
void logError(const std::string& message) {
  os_log_error(pluginLog(), "%{public}s", message.c_str());
}

}  // namespace aud_vst3
