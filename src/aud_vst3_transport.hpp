// @license
// Copyright (c) Audanika. All Rights Reserved.
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

// The DAW's transport as the transport of the graph (ticket 37): one segment
// per block with the DAW's tempo and time signature, at the DAW's position
// while it plays. While it is stopped the clock runs on at the DAW's tempo
// from where it stood, so that tempo-synced modulation - the scripts of a
// combi - keeps moving while the musician plays live; a configuration may
// stop it instead. The realtime thread owns the clock.

#ifndef AUD_VST3_TRANSPORT_HPP
#define AUD_VST3_TRANSPORT_HPP

#include <cstdint>

#include "aud_abi.h"

namespace aud_vst3 {

// #############################################################################
// What the DAW tells about its transport in one process call; a field whose
// flag is false is unknown.
struct HostTransport {
  bool tempoValid = false;
  double tempo = 120;
  bool playing = false;
  // The position in quarter notes (VST3's projectTimeMusic).
  bool positionValid = false;
  double position = 0;
  // The start of the current bar in quarter notes.
  bool barValid = false;
  double barStart = 0;
  bool signatureValid = false;
  uint32_t numerator = 4;
  uint32_t denominator = 4;
  // The loop (VST3's cycle) in quarter notes.
  bool looping = false;
  double loopStart = 0;
  double loopEnd = 0;
};

// #############################################################################
// The clock of the graph's transport; see above.
class TransportClock {
 public:
  // ...........................................................................
  // Creates a clock at beat 0 and 120 BPM; `freeRunning` keeps it moving
  // while the DAW is stopped.
  explicit TransportClock(bool freeRunning = true);

  // ...........................................................................
  // [realtime] Restarts at beat 0 for a new sample rate.
  void reset(double sampleRate);

  // ...........................................................................
  // [realtime] Describes a block of `frames` frames in `segment` and moves
  // on to the next block.
  void advance(const HostTransport& host, uint32_t frames,
               AudTransportSegment* segment);

  // ...........................................................................
  // The beat the next block starts at, in quarter notes.
  double beat() const { return beat_; }

 private:
  bool freeRunning_;
  double sampleRate_ = 48000;
  double beat_ = 0;
  double tempo_ = 120;
  bool started_ = false;
  bool wasPlaying_ = false;
};

}  // namespace aud_vst3

#endif  // AUD_VST3_TRANSPORT_HPP
