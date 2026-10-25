// @license
// Copyright (c) Audanika. All Rights Reserved.
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

#include "aud_vst3_bundle.hpp"

#include <cctype>

namespace aud_vst3 {

namespace {

// Whether `name` is `expected`, ignoring the case of ASCII letters as the
// file systems of macOS and Windows do.
bool sameName(const std::string& name, const char* expected) {
  size_t i = 0;
  for (; i < name.size() && expected[i] != '\0'; ++i) {
    if (std::tolower(static_cast<unsigned char>(name[i])) !=
        std::tolower(static_cast<unsigned char>(expected[i]))) {
      return false;
    }
  }
  return i == name.size() && expected[i] == '\0';
}

}  // namespace

// #############################################################################
std::string bundleOf(const std::string& binary) {
  const std::string architecture = containingFolder(binary);
  const std::string contents = containingFolder(architecture);
  if (contents.empty() || !sameName(lastName(contents), "Contents")) {
    return binary;
  }
  return containingFolder(contents);
}

// #############################################################################
std::string bundlePath() {
  const std::string binary = binaryPath();
  return binary.empty() ? binary : bundleOf(binary);
}

// #############################################################################
std::string resolvedBundlePath() { return resolvedPath(bundlePath()); }

// #############################################################################
std::string settingsDirectory() {
  return joinPath(resolvedBundlePath(), "Contents/Resources/aud_plugin");
}

}  // namespace aud_vst3
