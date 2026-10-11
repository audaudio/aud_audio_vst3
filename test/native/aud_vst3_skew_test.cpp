// @license
// Copyright (c) Audanika. All Rights Reserved.
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

// scripts/test-native.js runs this test once per flavor.

#include "aud_vst3_skew.hpp"

#include <cstddef>
#include <cstdint>
#include <string>
#include <vector>

#include "aud_vst3_harness.hpp"

using aud_vst3::SkewRegistry;
using aud_vst3::skewCheck;
using aud_vst3::skewRegistry;
using aud_vst3_test::expectEqual;
using aud_vst3_test::group;
using aud_vst3_test::test;

int main() {
  const std::string flavor = std::to_string(AUD_VST3_FLAVOR);
  const uint32_t otherFlavor = AUD_VST3_FLAVOR == 1 ? 2 : 1;
  // The registry and its claims, as the test compares them.
  const auto state = [] {
    return std::vector<uint32_t>{skewRegistry().flavor, skewRegistry().claims};
  };
  // Every test starts with a registry no image claimed.
  const auto reset = [] { skewRegistry() = SkewRegistry{}; };

  group("SkewRegistry", [&] {
    test("keeps the shared fields where flavor " + flavor + " has them", [&] {
      const size_t grown = AUD_VST3_FLAVOR == 2 ? 3 * sizeof(uint64_t) : 0;
      expectEqual(std::vector<size_t>{offsetof(SkewRegistry, flavor),
                                      offsetof(SkewRegistry, claims)},
                  std::vector<size_t>{grown, grown + sizeof(uint32_t)});
    });
  });

  group("skewCheck()", [&] {
    test("claims a registry nobody claimed for flavor " + flavor, [&] {
      reset();
      expectEqual(skewCheck(), true);
      expectEqual(state(),
                  std::vector<uint32_t>{AUD_VST3_FLAVOR, 1});
    });

    test("finds its own claim again", [&] {
      reset();
      skewCheck();
      expectEqual(skewCheck(), true);
      expectEqual(state(),
                  std::vector<uint32_t>{AUD_VST3_FLAVOR, 2});
    });

    test("refuses a registry flavor " + std::to_string(otherFlavor) +
             " claimed",
         [&] {
           reset();
           skewRegistry().flavor = otherFlavor;
           expectEqual(skewCheck(), false);
           expectEqual(state(), std::vector<uint32_t>{otherFlavor, 1});
         });
  });
  reset();
  return aud_vst3_test::finish();
}
