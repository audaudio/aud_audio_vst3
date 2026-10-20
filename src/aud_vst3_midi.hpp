// @license
// Copyright (c) Audanika. All Rights Reserved.
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

// The DAW's MIDI as events of the graph (ticket 37): note on, note off and
// poly pressure of VST3, and the control changes, channel pressure and pitch
// bend that a DAW hands a VST3 plugin only as parameters - one hidden
// parameter per channel and controller, assigned through IMidiMapping -,
// each as a MIDI 1.0 channel voice UMP at its sample offset on the graph's
// event input (port 0). The functions keep no state; the realtime thread
// calls them.

#ifndef AUD_VST3_MIDI_HPP
#define AUD_VST3_MIDI_HPP

#include <cstdint>

#include "aud_abi.h"

namespace aud_vst3 {

// #############################################################################
// The controllers of a channel that IMidiMapping assigns: the control changes
// 0 to 127, then channel pressure and pitch bend, numbered as VST3's
// ControllerNumbers (kAfterTouch, kPitchBend).
constexpr uint32_t kMidiChannels = 16;
constexpr uint32_t kMidiControllers = 130;
constexpr uint32_t kMidiChannelPressure = 128;
constexpr uint32_t kMidiPitchBend = 129;

// #############################################################################
// The first id of the hidden MIDI parameters: channel c, controller n has
// the id kMidiParamBase + c * kMidiControllers + n. The stable ids of graph
// parameters are FNV-1a hashes of 31 bits and may, rarely, fall into this
// range; the plugin then leaves the MIDI parameter out.
constexpr uint32_t kMidiParamBase = 0x7E000000u;

// #############################################################################
// The id of the hidden parameter of `controller` on `channel`.
uint32_t midiParamId(uint32_t channel, uint32_t controller);

// #############################################################################
// Whether `id` is a hidden MIDI parameter; then `channel` and `controller`
// name it.
bool midiParamOf(uint32_t id, uint32_t* channel, uint32_t* controller);

// #############################################################################
// A normalized value as a 7-bit MIDI value, rounded.
uint32_t sevenBits(double normalized);

// #############################################################################
// The event of a note on: `velocity` from 0 to 1 becomes 1 to 127, since a
// MIDI note on of velocity 0 is a note off.
AudEvent noteOnEvent(uint32_t channel, uint32_t pitch, float velocity,
                     uint32_t offset);

// #############################################################################
// The event of a note off with its release velocity.
AudEvent noteOffEvent(uint32_t channel, uint32_t pitch, float velocity,
                      uint32_t offset);

// #############################################################################
// The event of poly pressure on one note.
AudEvent polyPressureEvent(uint32_t channel, uint32_t pitch, float pressure,
                           uint32_t offset);

// #############################################################################
// The event of control change `cc` with a 7-bit `value`.
AudEvent controlChangeEvent(uint32_t channel, uint32_t cc, uint32_t value,
                            uint32_t offset);

// #############################################################################
// The event of a hidden MIDI parameter's value: a control change, channel
// pressure, or a pitch bend of 14 bits whose centre is the normalized 0.5.
AudEvent midiParamEvent(uint32_t channel, uint32_t controller,
                        double normalized, uint32_t offset);

}  // namespace aud_vst3

#endif  // AUD_VST3_MIDI_HPP
