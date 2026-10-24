// @license
// Copyright (c) Audanika. All Rights Reserved.
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

// The macOS part of aud_vst3_bundle.hpp: the bundle through dladdr, links
// through realpath, apps through NSWorkspace, the unified log.

#include "aud_vst3_bundle.hpp"

#import <AppKit/AppKit.h>
#include <dlfcn.h>
#include <limits.h>
#include <os/log.h>
#include <stdlib.h>
#include <unistd.h>

#include "aud_vst3_config.hpp"

namespace aud_vst3 {

namespace {

os_log_t pluginLog() {
  static os_log_t log = os_log_create(AUD_VST3_BUNDLE_ID, "plugin");
  return log;
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
std::string appWithIdentifier(const std::string& identifier) {
  @autoreleasepool {
    NSString* id = [NSString stringWithUTF8String:identifier.c_str()];
    NSURL* url = [[NSWorkspace sharedWorkspace]
        URLForApplicationWithBundleIdentifier:id];
    return url != nil ? std::string(url.path.UTF8String) : std::string();
  }
}

// #############################################################################
void systemLog(bool error, const std::string& message) {
  if (error) {
    os_log_error(pluginLog(), "%{public}s", message.c_str());
  } else {
    os_log_info(pluginLog(), "%{public}s", message.c_str());
  }
}

// #############################################################################
long processId() { return static_cast<long>(getpid()); }

}  // namespace aud_vst3
