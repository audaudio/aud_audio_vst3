// @license
// Copyright (c) Audanika. All Rights Reserved.
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

#include "aud_vst3_transport.hpp"

#include <cmath>

namespace aud_vst3 {

namespace {

// A jump of the DAW's position by more than this, in quarter notes, is a
// discontinuity; a playing DAW's position drifts by rounding only.
constexpr double kJump = 1e-3;

int64_t ticksOf(double quarterNotes) {
  return static_cast<int64_t>(
      std::llround(quarterNotes * static_cast<double>(AUD_BEAT_FACTOR)));
}

}  // namespace

// #############################################################################
TransportClock::TransportClock(bool freeRunning) : freeRunning_(freeRunning) {}

// .............................................................................
void TransportClock::reset(double sampleRate) {
  sampleRate_ = sampleRate > 0 ? sampleRate : 48000;
  beat_ = 0;
  started_ = false;
  wasPlaying_ = false;
}

// .............................................................................
void TransportClock::advance(const HostTransport& host, uint32_t frames,
                             AudTransportSegment* segment) {
  if (host.tempoValid && std::isfinite(host.tempo) && host.tempo > 0) {
    tempo_ = host.tempo;
  }
  uint32_t flags = 0;
  const bool following = host.playing && host.positionValid &&
                         std::isfinite(host.position);
  if (following) {
    if (!started_ || !wasPlaying_ || std::fabs(host.position - beat_) > kJump) {
      flags |= AUD_SEGMENT_DISCONTINUITY;
    }
    beat_ = host.position;
  } else if (!started_) {
    flags |= AUD_SEGMENT_DISCONTINUITY;
  }
  const bool moving = following || freeRunning_;
  if (moving) flags |= AUD_SEGMENT_PLAYING;
  if (host.looping && host.loopEnd > host.loopStart) {
    flags |= AUD_SEGMENT_LOOPING;
  }

  const uint32_t numerator = host.signatureValid && host.numerator > 0
                                 ? host.numerator
                                 : 4;
  const uint32_t denominator = host.signatureValid && host.denominator > 0
                                   ? host.denominator
                                   : 4;
  // The bar's start: the DAW's while it follows the DAW, else counted from
  // beat 0 in bars of the time signature.
  double barStart = 0;
  if (following && host.barValid && std::isfinite(host.barStart)) {
    barStart = host.barStart;
  } else {
    const double barLength = numerator * 4.0 / denominator;
    barStart = std::floor(beat_ / barLength) * barLength;
  }

  *segment = AudTransportSegment{};
  segment->struct_size = sizeof(AudTransportSegment);
  segment->sample_offset = 0;
  segment->frames = frames;
  segment->flags = flags;
  segment->beat = ticksOf(beat_);
  segment->tempo = tempo_;
  segment->tempo_increment = 0;
  segment->bar_start = ticksOf(barStart);
  segment->time_signature_numerator = numerator;
  segment->time_signature_denominator = denominator;
  segment->loop_start = ticksOf(host.loopStart);
  segment->loop_end = ticksOf(host.loopEnd);

  if (moving) beat_ += frames / sampleRate_ * tempo_ / 60.0;
  started_ = true;
  wasPlaying_ = following;
}

}  // namespace aud_vst3
