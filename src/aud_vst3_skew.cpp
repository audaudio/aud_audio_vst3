// @license
// Copyright (c) Audanika. All Rights Reserved.
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

#include "aud_vst3_skew.hpp"

namespace aud_vst3 {

bool skewCheck() {
  SkewRegistry& registry = skewRegistry();
  if (registry.flavor == 0) registry.flavor = AUD_VST3_FLAVOR;
  registry.claims += 1;
  return registry.flavor == AUD_VST3_FLAVOR;
}

}  // namespace aud_vst3
