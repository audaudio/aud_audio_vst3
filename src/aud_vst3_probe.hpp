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

// #############################################################################
// [any thread] The current time in nanoseconds of mach_absolute_time.
int64_t nowNs();

// #############################################################################
// A value as the probe writes it: nine decimals, so that the records of
// one change match across threads and processes.
std::string probeNumber(double value);

// #############################################################################
// Whether `kind` can name a record: one or more ASCII letters. The kind
// goes into the JSON line as it is, without escapes.
bool isProbeKind(const std::string& kind);

// #############################################################################
// The directory of the probe's logs and the editor's output,
// ~/Library/Logs/aud_audio_vst3.
std::string logDirectory();

// #############################################################################
// A record of the realtime thread.
struct ProbeRecord {
  // ...........................................................................
  // The ProbeKind, and the parameter id of a kProbeProcess record.
  int32_t kind;
  uint32_t id;

  // ...........................................................................
  // The time in nanoseconds of mach_absolute_time.
  int64_t stamp;

  // ...........................................................................
  // The normalized value and its sample offset in the block; the count of
  // changes passed on and 0 in a kProbeRendered record.
  double value;
  int32_t offset;

  // ...........................................................................
  // Unused, 0.
  uint32_t reserved;
};

// #############################################################################
// The kinds of the realtime thread's records.
enum ProbeKind : int32_t {
  // process() received a parameter change.
  kProbeProcess = 1,
  // process() rendered the first block after the control thread passed a
  // change on to the engine.
  kProbeRendered = 2,
};

// #############################################################################
// The probe of one plugin instance; see above.
class Probe {
 public:
  // ...........................................................................
  // Opens the log of this process for plugin instance `instance`.
  explicit Probe(uint32_t instance);

  // ...........................................................................
  // Stops the watch of the UI thread, writes the waiting records and
  // closes the log.
  ~Probe();

  // ...........................................................................
  // Not copyable: the watch thread and the log belong to this object.
  Probe(const Probe&) = delete;
  Probe& operator=(const Probe&) = delete;

  // ...........................................................................
  // [realtime] Pushes a record; drops it when the ring is full.
  void push(const ProbeRecord& record) {
    if (!ring_.push(record)) dropped_.fetch_add(1, std::memory_order_relaxed);
  }

  // ...........................................................................
  // [control] Writes the waiting records of the realtime thread.
  void drain();

  // ...........................................................................
  // [any non-realtime thread] Writes one JSON object as a line; `fields`
  // is the inside of the object without braces.
  void write(const char* kind, const std::string& fields);

  // ...........................................................................
  // The number of the plugin instance.
  uint32_t instance() const { return instance_; }

  // ...........................................................................
  // Watches the host's UI thread: a thread posts a block to the main queue
  // every 10 ms and writes the longest delay of each second as `uiStall`.
  void startUiWatch();

  // ...........................................................................
  // Stops the watch and waits for its thread.
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
