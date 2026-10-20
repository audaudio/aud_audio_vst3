// @license
// Copyright (c) Audanika. All Rights Reserved.
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

// The DAW's transport as the graph's (aud_vst3_transport.hpp).

#include "aud_vst3_transport.hpp"

#include "aud_transport.h"
#include "aud_vst3_harness.hpp"

using namespace aud_vst3;
using aud_vst3_test::expectEqual;
using aud_vst3_test::expectNear;
using aud_vst3_test::group;
using aud_vst3_test::test;

namespace {

double beatOf(const AudTransportSegment& segment) {
  return aud_beats_from_ticks(segment.beat);
}

bool has(const AudTransportSegment& segment, uint32_t flag) {
  return (segment.flags & flag) != 0;
}

}  // namespace

int main() {
  group("a stopped DAW", [] {
    test("the free clock plays at the DAW's tempo from beat 0", [] {
      TransportClock clock(true);
      clock.reset(48000);
      HostTransport host;
      host.tempoValid = true;
      host.tempo = 60;
      AudTransportSegment segment{};
      clock.advance(host, 24000, &segment);
      expectEqual(has(segment, AUD_SEGMENT_PLAYING), true);
      expectEqual(has(segment, AUD_SEGMENT_DISCONTINUITY), true);
      expectNear(beatOf(segment), 0, 1e-9);
      expectNear(segment.tempo, 60, 1e-9);
      clock.advance(host, 24000, &segment);
      expectEqual(has(segment, AUD_SEGMENT_DISCONTINUITY), false);
      expectNear(beatOf(segment), 0.5, 1e-6);
    });
    test("without the free clock the beat stands", [] {
      TransportClock clock(false);
      clock.reset(48000);
      HostTransport host;
      AudTransportSegment segment{};
      clock.advance(host, 48000, &segment);
      clock.advance(host, 48000, &segment);
      expectEqual(has(segment, AUD_SEGMENT_PLAYING), false);
      expectNear(beatOf(segment), 0, 1e-9);
      expectNear(segment.tempo, 120, 1e-9);
    });
  });

  group("a playing DAW", [] {
    test("is followed, a jump is a discontinuity", [] {
      TransportClock clock(true);
      clock.reset(48000);
      HostTransport host;
      host.tempoValid = true;
      host.tempo = 120;
      host.playing = true;
      host.positionValid = true;
      host.position = 8;
      AudTransportSegment segment{};
      clock.advance(host, 24000, &segment);
      expectEqual(has(segment, AUD_SEGMENT_DISCONTINUITY), true);
      expectNear(beatOf(segment), 8, 1e-6);
      host.position = 9;  // 24000 frames at 120 BPM: one beat on
      clock.advance(host, 24000, &segment);
      expectEqual(has(segment, AUD_SEGMENT_DISCONTINUITY), false);
      host.position = 32;
      clock.advance(host, 24000, &segment);
      expectEqual(has(segment, AUD_SEGMENT_DISCONTINUITY), true);
      expectNear(beatOf(segment), 32, 1e-6);
    });
    test("a stop keeps the beat moving on from where the DAW stood", [] {
      TransportClock clock(true);
      clock.reset(48000);
      HostTransport host;
      host.tempoValid = true;
      host.tempo = 120;
      host.playing = true;
      host.positionValid = true;
      host.position = 4;
      AudTransportSegment segment{};
      clock.advance(host, 24000, &segment);
      host.playing = false;
      clock.advance(host, 24000, &segment);
      expectEqual(has(segment, AUD_SEGMENT_PLAYING), true);
      expectNear(beatOf(segment), 5, 1e-6);
    });
    test("time signature, bar and loop", [] {
      TransportClock clock(true);
      clock.reset(44100);
      HostTransport host;
      host.playing = true;
      host.positionValid = true;
      host.position = 7.5;
      host.barValid = true;
      host.barStart = 6;
      host.signatureValid = true;
      host.numerator = 3;
      host.denominator = 4;
      host.looping = true;
      host.loopStart = 4;
      host.loopEnd = 16;
      AudTransportSegment segment{};
      clock.advance(host, 512, &segment);
      expectEqual(segment.time_signature_numerator, 3u);
      expectEqual(segment.time_signature_denominator, 4u);
      expectNear(aud_beats_from_ticks(segment.bar_start), 6, 1e-9);
      expectEqual(has(segment, AUD_SEGMENT_LOOPING), true);
      expectNear(aud_beats_from_ticks(segment.loop_end), 16, 1e-9);
      expectEqual(segment.frames, 512u);
    });
  });
  return aud_vst3_test::finish();
}
