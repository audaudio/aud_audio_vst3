// @license
// Copyright (c) Audanika. All Rights Reserved.
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

#include "aud_vst3_bundle.hpp"

#include <algorithm>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <system_error>

namespace aud_vst3 {

namespace {

#if _WIN32
constexpr char kSeparator = '\\';
#else
constexpr char kSeparator = '/';
#endif

bool startsWith(const std::string& text, const std::string& prefix) {
  return text.compare(0, prefix.size(), prefix) == 0;
}

void logToFile(const char* level, const std::string& message) {
  const std::string file = logFile();
  if (file.empty()) return;
  std::ofstream out(std::filesystem::u8path(file), std::ios::app);
  if (out) out << level << ' ' << processId() << ' ' << message << '\n';
}

}  // namespace

// #############################################################################
std::string settingsDirectory() {
  return joinPath(resolvedBundlePath(), "Contents/Resources/aud_plugin");
}

// #############################################################################
std::string containingApp(const std::string& path) {
  // The outermost .app wins: a helper app inside a plugin inside an app
  // belongs to the app.
  const size_t at = std::min(path.find(".app/"), path.find(".app\\"));
  if (at != std::string::npos) return path.substr(0, at + 4);
  if (path.size() >= 4 && path.compare(path.size() - 4, 4, ".app") == 0) {
    return path;
  }
  return {};
}

// #############################################################################
std::string containingFolder(const std::string& path) {
  std::string folder = path;
  // A trailing separator names the same path.
  while (folder.size() > 1 && (folder.back() == '/' || folder.back() == '\\')) {
    folder.pop_back();
  }
  const size_t at = folder.find_last_of("/\\");
  if (at == std::string::npos) return {};
  // The root of a drive or of the file system keeps its separator.
  if (at == 0 || (at == 2 && folder[1] == ':')) return folder.substr(0, at + 1);
  return folder.substr(0, at);
}

// #############################################################################
std::string joinPath(const std::string& path, const std::string& relative) {
  std::string result = path;
  if (!result.empty() && result.back() != '/' && result.back() != '\\') {
    result += kSeparator;
  }
  for (const char c : relative) result += c == '/' ? kSeparator : c;
  return result;
}

// #############################################################################
bool isDirectory(const std::string& path) {
  if (path.empty()) return false;
  std::error_code error;
  return std::filesystem::is_directory(std::filesystem::u8path(path), error);
}

// #############################################################################
bool isFile(const std::string& path) {
  if (path.empty()) return false;
  std::error_code error;
  return std::filesystem::is_regular_file(std::filesystem::u8path(path), error);
}

// #############################################################################
std::string locate(const std::string& location, const std::string& bundle) {
  if (startsWith(location, "containing-app:")) {
    const std::string app = containingApp(bundle);
    return app.empty() ? std::string() : joinPath(app, location.substr(15));
  }
  if (startsWith(location, "containing-folder:")) {
    const std::string folder = containingFolder(bundle);
    return folder.empty() ? std::string() : joinPath(folder, location.substr(18));
  }
  if (startsWith(location, "app:")) {
    const size_t colon = location.find(':', 4);
    if (colon == std::string::npos) return {};
    const std::string app = appWithIdentifier(location.substr(4, colon - 4));
    return app.empty() ? std::string() : joinPath(app, location.substr(colon + 1));
  }
  if (startsWith(location, "bundle:")) return joinPath(bundle, location.substr(7));
  return {};
}

// #############################################################################
std::string contentDirectory(const std::vector<std::string>& locations,
                             const std::string& bundle) {
  for (const std::string& location : locations) {
    const std::string candidate = locate(location, bundle);
    if (isDirectory(candidate)) return candidate;
  }
  return {};
}

// #############################################################################
std::string logFile() {
  const char* file = std::getenv("AUD_VST3_LOG");
  return file != nullptr ? file : "";
}

// #############################################################################
void logInfo(const std::string& message) {
  systemLog(false, message);
  logToFile("info", message);
}

// #############################################################################
void logError(const std::string& message) {
  systemLog(true, message);
  logToFile("error", message);
}

}  // namespace aud_vst3
