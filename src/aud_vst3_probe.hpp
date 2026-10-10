// @license
// Copyright (c) Audanika. All Rights Reserved.
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

// The measurement probes of the spike (ticket 24). Every stamp is
// mach_absolute_time in nanoseconds, valid across processes, so the editor
// process and the plugin share one clock. The realtime thread only pushes
// fixed-size records into a lock-free ring; the control thread drains it and
// writes JSON lines to ~/Library/Logs/aud_audio_vst3/probe-<pid>.jsonl.
// Other threads write through a mutex.

#ifndef AUD_VST3_PROBE_HPP
#define AUD_VST3_PROBE_HPP

#include <atomic>
#include <cstdint>
#include <cstdio>
#include <mutex>
#include <string>
#include <thread>

#include "aud_spsc_queue.hpp"

namespace aud_vst3 {

// [any thread] The current time in nanoseconds of mach_absolute_time.
int64_t nowNs();

// A value as the probe writes it: nine decimals, so that the records of
// one change match across threads and processes.
std::string probeNumber(double value);

// A record of the realtime thread.
struct ProbeRecord {
  int32_t kind;  // ProbeKind
  uint32_t id;   // the parameter id
  int64_t stamp;
  double value;  // the normalized value
  int32_t offset;
  uint32_t reserved;
};

enum ProbeKind : int32_t {
  // process() received a parameter change.
  kProbeProcess = 1,
  // process() rendered the first block after the control thread passed a
  // change on to the engine.
  kProbeRendered = 2,
};

class Probe {
 public:
  explicit Probe(uint32_t instance);
  ~Probe();

  Probe(const Probe&) = delete;
  Probe& operator=(const Probe&) = delete;

  // [realtime] Pushes a record; drops it when the ring is full.
  void push(const ProbeRecord& record) {
    if (!ring_.push(record)) dropped_.fetch_add(1, std::memory_order_relaxed);
  }

  // [control] Writes the waiting records of the realtime thread.
  void drain();

  // [any non-realtime thread] Writes one JSON object as a line; `fields`
  // is the inside of the object without braces.
  void write(const char* kind, const std::string& fields);

  uint32_t instance() const { return instance_; }

  // Watches the host's UI thread: a thread posts a block to the main queue
  // every 10 ms and writes the longest delay of each second as `uiStall`.
  void startUiWatch();
  void stopUiWatch();

 private:
  void writeLine(const std::string& line);

  const uint32_t instance_;
  AudSpscQueue<ProbeRecord> ring_;
  std::atomic<uint64_t> dropped_{0};
  uint64_t reportedDropped_ = 0;
  std::mutex mutex_;
  FILE* file_ = nullptr;
  std::atomic<bool> watching_{false};
  std::thread watch_;
};

}  // namespace aud_vst3

#endif  // AUD_VST3_PROBE_HPP
