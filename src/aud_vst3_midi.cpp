// @license
// Copyright (c) Audanika. All Rights Reserved.
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

#include "aud_vst3_midi.hpp"

#include <algorithm>
#include <cmath>

#include "aud_ump.h"

namespace aud_vst3 {

namespace {

constexpr uint32_t kNoteOff = 0x80;
constexpr uint32_t kNoteOn = 0x90;
constexpr uint32_t kPolyPressure = 0xA0;
constexpr uint32_t kControlChange = 0xB0;
constexpr uint32_t kChannelPressure = 0xD0;
constexpr uint32_t kPitchBend = 0xE0;

double clamp01(double value) {
  return std::isfinite(value) ? std::min(1.0, std::max(0.0, value)) : 0.0;
}

AudEvent eventOf(uint32_t status, uint32_t channel, uint32_t data1,
                 uint32_t data2, uint32_t offset) {
  const uint32_t word =
      aud_ump_midi1_word(0, status | (channel & 0xF), data1, data2);
  return aud_event_ump(&word, 1, offset, 0);
}

}  // namespace

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
uint32_t sevenBits(double normalized) {
  return static_cast<uint32_t>(std::lround(clamp01(normalized) * 127.0));
}

// #############################################################################
AudEvent noteOnEvent(uint32_t channel, uint32_t pitch, float velocity,
                     uint32_t offset) {
  return eventOf(kNoteOn, channel, pitch & 0x7F,
                 std::max<uint32_t>(1, sevenBits(velocity)), offset);
}

// #############################################################################
AudEvent noteOffEvent(uint32_t channel, uint32_t pitch, float velocity,
                      uint32_t offset) {
  return eventOf(kNoteOff, channel, pitch & 0x7F, sevenBits(velocity), offset);
}

// #############################################################################
AudEvent polyPressureEvent(uint32_t channel, uint32_t pitch, float pressure,
                           uint32_t offset) {
  return eventOf(kPolyPressure, channel, pitch & 0x7F, sevenBits(pressure),
                 offset);
}

// #############################################################################
AudEvent controlChangeEvent(uint32_t channel, uint32_t cc, uint32_t value,
                            uint32_t offset) {
  return eventOf(kControlChange, channel, cc & 0x7F, std::min(value, 127u),
                 offset);
}

// #############################################################################
AudEvent midiEvent(uint32_t status, uint32_t data1, uint32_t data2,
                   uint32_t offset) {
  const uint32_t word = aud_ump_midi1_word(0, status & 0xFF, data1, data2);
  return aud_event_ump(&word, 1, offset, 0);
}

// #############################################################################
uint32_t midiDataBytes(uint32_t status) {
  switch (status & 0xF0) {
    case 0x80:
    case 0x90:
    case 0xA0:
    case 0xB0:
    case 0xE0:
      return 2;
    case 0xC0:
    case 0xD0:
      return 1;
    default:
      return 0;
  }
}

// #############################################################################
AudEvent midiParamEvent(uint32_t channel, uint32_t controller,
                        double normalized, uint32_t offset) {
  if (controller == kMidiPitchBend) {
    const uint32_t bend =
        static_cast<uint32_t>(std::lround(clamp01(normalized) * 16383.0));
    return eventOf(kPitchBend, channel, bend & 0x7F, bend >> 7, offset);
  }
  if (controller == kMidiChannelPressure) {
    return eventOf(kChannelPressure, channel, sevenBits(normalized), 0,
                   offset);
  }
  return controlChangeEvent(channel, controller, sevenBits(normalized),
                            offset);
}

}  // namespace aud_vst3
