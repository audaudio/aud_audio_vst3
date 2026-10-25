// @license
// Copyright (c) Audanika. All Rights Reserved.
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

// The control changes, channel pressure and pitch bend that a DAW hands a
// VST3 plugin only as parameters (ticket 37) - one hidden parameter per
// channel and controller, assigned through IMidiMapping -, as events of the
// graph. Notes and poly pressure, which VST3 hands over as events, and the
// events themselves come from aud_audio_plugin (aud_plugin_midi.hpp). The
// functions keep no state; the realtime thread calls them.

#ifndef AUD_VST3_MIDI_HPP
#define AUD_VST3_MIDI_HPP

#include <cstdint>

#include "aud_vst3_shared.hpp"

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
// The event of a hidden MIDI parameter's value: a control change, channel
// pressure, or a pitch bend of 14 bits whose centre is the normalized 0.5.
AudEvent midiParamEvent(uint32_t channel, uint32_t controller,
                        double normalized, uint32_t offset);

}  // namespace aud_vst3

#endif  // AUD_VST3_MIDI_HPP
