// @license
// Copyright (c) Audanika. All Rights Reserved.
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

// The deliberate engine skew of the two-engine test (ticket 24). Two plugins
// built from different engine versions share inline functions and types by
// name. dyld coalesces exported weak definitions across the images of a
// process, so with default visibility the second plugin may run the first
// plugin's copy of an inline function - with the first plugin's data
// layout. Flavor 2 changes the layout of SkewRegistry; skewCheck() notices
// when the registry it reaches belongs to the other flavor.

#ifndef AUD_VST3_SKEW_HPP
#define AUD_VST3_SKEW_HPP

#include <cstdint>

#include "aud_vst3_config.hpp"

namespace aud_vst3 {

struct SkewRegistry {
#if AUD_VST3_FLAVOR == 2
  // Flavor 2 grew members before the fields both flavors share.
  uint64_t grown[3];
#endif
  uint32_t flavor;
  uint32_t claims;
};

// A function-local static of an inline function: one weak definition per
// image, coalesced across images unless hidden.
inline SkewRegistry& skewRegistry() {
  static SkewRegistry registry{};
  return registry;
}

// Claims the registry for this image's flavor; false when the registry the
// image reaches was claimed by the other flavor or has the other layout.
bool skewCheck();

}  // namespace aud_vst3

#endif  // AUD_VST3_SKEW_HPP
