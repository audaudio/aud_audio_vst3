// @license
// Copyright (c) Audanika. All Rights Reserved.
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

// The node packages of a plugin build (ticket 37). scripts/build-plugin.js
// compiles the packages that plugin.json names into the binary and
// generates the definitions of these functions for them; a build without
// packages has the graph's own nodes only.

#ifndef AUD_VST3_PACKAGES_HPP
#define AUD_VST3_PACKAGES_HPP

#include <cstdint>
#include <string>

#include "aud_audio_graph.h"

namespace aud_vst3 {

// #############################################################################
// [control] Registers the node packages of the build with `graph`, in the
// order plugin.json names them; false with `error` when one refuses.
bool registerPackages(AudGraph* graph, std::string* error);

// #############################################################################
// [any thread] Sets the voice budget of the samplers of the process where
// the build has aud_dsp_sampler; 0 lifts it.
void setVoiceBudget(int32_t voices);

}  // namespace aud_vst3

#endif  // AUD_VST3_PACKAGES_HPP
