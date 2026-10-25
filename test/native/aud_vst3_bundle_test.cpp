// @license
// Copyright (c) Audanika. All Rights Reserved.
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

// Where the plugin is (aud_vst3_bundle.hpp): the .vst3 bundle around its
// binary on macOS and Windows (tickets 37 and 38). The paths around a
// bundle are aud_audio_plugin's, tested there.

#include "aud_vst3_bundle.hpp"

#include <string>

#include "aud_vst3_harness.hpp"

using namespace aud_vst3;
using aud_vst3_test::expectEqual;
using aud_vst3_test::group;
using aud_vst3_test::test;

int main() {
  group("bundleOf", [] {
    test("is the bundle around the binary on macOS", [] {
      expectEqual(bundleOf("/Library/A.app/Contents/PlugIns/A.vst3/Contents/MacOS/A"),
                  std::string("/Library/A.app/Contents/PlugIns/A.vst3"));
    });
    test("is the bundle around the binary on Windows", [] {
      expectEqual(bundleOf("C:\\App\\A.vst3\\Contents\\x86_64-win\\A.vst3"),
                  std::string("C:\\App\\A.vst3"));
    });
    test("takes Contents in any case, as the file systems do", [] {
      expectEqual(bundleOf("C:\\App\\A.vst3\\contents\\x86_64-win\\A.vst3"),
                  std::string("C:\\App\\A.vst3"));
    });
    test("is the binary itself for a plugin of one file", [] {
      expectEqual(bundleOf("C:\\Plugins\\A.vst3"), std::string("C:\\Plugins\\A.vst3"));
      expectEqual(bundleOf("C:\\Plugins\\x86_64-win\\A.vst3"),
                  std::string("C:\\Plugins\\x86_64-win\\A.vst3"));
    });
  });

  group("settingsDirectory", [] {
    test("is Resources/aud_plugin inside the bundle", [] {
      const std::string directory = settingsDirectory();
      const std::string tail = joinPath("Contents", "Resources/aud_plugin");
      expectEqual(directory.size() >= tail.size() &&
                      directory.compare(directory.size() - tail.size(),
                                        tail.size(), tail) == 0,
                  true);
    });
  });

  return aud_vst3_test::finish();
}
