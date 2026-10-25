// @license
// Copyright (c) Audanika. All Rights Reserved.
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

// The DAW's controllers as events of the graph (aud_vst3_midi.hpp).

#include "aud_vst3_midi.hpp"

#include "aud_ump.h"
#include "aud_vst3_harness.hpp"

using namespace aud_vst3;
using aud_vst3_test::expectEqual;
using aud_vst3_test::group;
using aud_vst3_test::test;

namespace {

// The status byte, the data bytes, the port and the offset of an event.
struct Midi {
  uint32_t status;
  uint32_t data1;
  uint32_t data2;
};

Midi midiOf(const AudEvent& event) {
  const uint32_t word = event.words[0];
  return {(word >> 16) & 0xFF, (word >> 8) & 0x7F, word & 0x7F};
}

}  // namespace

int main() {
  group("parameter ids", [] {
    test("cover 16 channels of 130 controllers", [] {
      expectEqual(midiParamId(0, 0), kMidiParamBase);
      expectEqual(midiParamId(15, 129), kMidiParamBase + 16 * 130 - 1);
      uint32_t channel = 99, controller = 99;
      expectEqual(midiParamOf(midiParamId(3, 74), &channel, &controller), true);
      expectEqual(channel, 3u);
      expectEqual(controller, 74u);
      expectEqual(midiParamOf(kMidiParamBase - 1, &channel, &controller), false);
      expectEqual(midiParamOf(kMidiParamBase + 16 * 130, nullptr, nullptr), false);
    });
  });

  group("controllers", [] {
    test("a control change rounds to 7 bits", [] {
      const Midi cc = midiOf(midiParamEvent(0, 74, 0.5, 3));
      expectEqual(cc.status, 0xB0u);
      expectEqual(cc.data1, 74u);
      expectEqual(cc.data2, 64u);
      expectEqual(sevenBits(-1), 0u);
      expectEqual(sevenBits(2), 127u);
    });
    test("channel pressure", [] {
      const Midi pressure = midiOf(midiParamEvent(4, kMidiChannelPressure, 1, 0));
      expectEqual(pressure.status, 0xD4u);
      expectEqual(pressure.data1, 127u);
    });
    test("pitch bend has 14 bits, centred at 0.5", [] {
      const Midi centre = midiOf(midiParamEvent(0, kMidiPitchBend, 0.5, 0));
      expectEqual(centre.status, 0xE0u);
      expectEqual(centre.data1 | (centre.data2 << 7), 8192u);
      const Midi top = midiOf(midiParamEvent(0, kMidiPitchBend, 1, 0));
      expectEqual(top.data1 | (top.data2 << 7), 16383u);
      const Midi bottom = midiOf(midiParamEvent(0, kMidiPitchBend, 0, 0));
      expectEqual(bottom.data1 | (bottom.data2 << 7), 0u);
    });
  });
  return aud_vst3_test::finish();
}
