// @license
// Copyright (c) Audanika. All Rights Reserved.
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

#include "aud_vst3_midi.hpp"

namespace aud_vst3 {

// #############################################################################
uint32_t midiParamId(uint32_t channel, uint32_t controller) {
  return kMidiParamBase + channel * kMidiControllers + controller;
}

// #############################################################################
bool midiParamOf(uint32_t id, uint32_t* channel, uint32_t* controller) {
  if (id < kMidiParamBase ||
      id >= kMidiParamBase + kMidiChannels * kMidiControllers) {
    return false;
  }
  const uint32_t index = id - kMidiParamBase;
  if (channel != nullptr) *channel = index / kMidiControllers;
  if (controller != nullptr) *controller = index % kMidiControllers;
  return true;
}

// #############################################################################
AudEvent midiParamEvent(uint32_t channel, uint32_t controller,
                        double normalized, uint32_t offset) {
  if (controller == kMidiPitchBend) {
    return pitchBendEvent(channel, normalized, offset);
  }
  if (controller == kMidiChannelPressure) {
    return channelPressureEvent(channel, normalized, offset);
  }
  return controlChangeEvent(channel, controller, sevenBits(normalized),
                            offset);
}

}  // namespace aud_vst3
