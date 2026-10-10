// @license
// Copyright (c) Audanika. All Rights Reserved.
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

#include "aud_vst3_probe.hpp"

#include "aud_vst3_config.hpp"

#include <dispatch/dispatch.h>
#include <mach/mach_time.h>
#include <sys/stat.h>
#include <unistd.h>

#include <algorithm>
#include <cinttypes>
#include <cstdlib>

namespace aud_vst3 {

namespace {

mach_timebase_info_data_t timebase() {
  mach_timebase_info_data_t info{};
  mach_timebase_info(&info);
  return info;
}

std::string logDirectory() {
  const char* home = std::getenv("HOME");
  return std::string(home != nullptr ? home : "/tmp") +
         "/Library/Logs/aud_audio_vst3";
}

}  // namespace

int64_t nowNs() {
  static const mach_timebase_info_data_t info = timebase();
  const uint64_t ticks = mach_absolute_time();
  return static_cast<int64_t>(ticks * info.numer / info.denom);
}

std::string probeNumber(double value) {
  char text[32];
  std::snprintf(text, sizeof(text), "%.9f", value);
  return text;
}

Probe::Probe(uint32_t instance) : instance_(instance), ring_(4096) {
  // Initializes the timebase before the realtime thread reads the clock.
  nowNs();
  const std::string dir = logDirectory();
  mkdir(dir.c_str(), 0755);
  const std::string path =
      dir + "/probe-" + std::to_string(getpid()) + ".jsonl";
  // "e": close-on-exec, so that the editor process does not inherit it.
  file_ = std::fopen(path.c_str(), "ae");
}

Probe::~Probe() {
  stopUiWatch();
  drain();
  if (file_ != nullptr) std::fclose(file_);
}

void Probe::drain() {
  ProbeRecord record{};
  char line[256];
  while (ring_.pop(record)) {
    const char* kind = record.kind == kProbeProcess ? "process" : "rendered";
    std::snprintf(line, sizeof(line),
                  "{\"kind\":\"%s\",\"build\":\"%c%d\",\"instance\":%u,"
                  "\"id\":%u,\"value\":%.9f,\"offset\":%d,\"t\":%" PRId64 "}",
                  kind, kVariant, kFlavor, instance_, record.id, record.value,
                  record.offset, record.stamp);
    writeLine(line);
  }
  const uint64_t dropped = dropped_.load(std::memory_order_relaxed);
  if (dropped != reportedDropped_) {
    reportedDropped_ = dropped;
    write("dropped", "\"count\":" + std::to_string(dropped));
  }
}

void Probe::write(const char* kind, const std::string& fields) {
  std::string line = std::string("{\"kind\":\"") + kind + "\",\"build\":\"" +
                     kVariant + std::to_string(kFlavor) +
                     "\",\"instance\":" + std::to_string(instance_) +
                     ",\"t\":" + std::to_string(nowNs());
  if (!fields.empty()) line += "," + fields;
  line += "}";
  writeLine(line);
}

void Probe::startUiWatch() {
  if (watching_.exchange(true)) return;
  watch_ = std::thread([this] {
    int64_t worst = 0;
    int64_t windowStart = nowNs();
    while (watching_.load()) {
      const int64_t posted = nowNs();
      dispatch_semaphore_t done = dispatch_semaphore_create(0);
      __block int64_t ran = 0;
      // In C++ a block does not retain what it captures: the block keeps its
      // own reference, for a UI thread that runs it after the wait gave up.
      dispatch_retain(done);
      dispatch_async(dispatch_get_main_queue(), ^{
        ran = nowNs();
        dispatch_semaphore_signal(done);
        dispatch_release(done);
      });
      // A stalled UI thread counts until it runs the block, at most 2 s. The
      // wait runs in slices: stopUiWatch() joins this thread on the UI
      // thread, which then cannot run the block. Only a signalled wait may
      // read `ran`: after a timeout the block may still be writing it.
      bool signalled = false;
      while (watching_.load() && nowNs() - posted < 2'000'000'000) {
        if (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 5'000'000)) == 0) {
          signalled = true;
          break;
        }
      }
      dispatch_release(done);
      if (!signalled && !watching_.load()) break;
      worst = std::max(worst, (signalled ? ran : nowNs()) - posted);
      if (nowNs() - windowStart >= 1000000000) {
        write("uiStall", "\"worstNs\":" + std::to_string(worst));
        worst = 0;
        windowStart = nowNs();
      }
      usleep(10000);
    }
  });
}

void Probe::stopUiWatch() {
  if (!watching_.exchange(false)) return;
  if (watch_.joinable()) watch_.join();
}

void Probe::writeLine(const std::string& line) {
  std::lock_guard<std::mutex> lock(mutex_);
  if (file_ == nullptr) return;
  std::fputs(line.c_str(), file_);
  std::fputc('\n', file_);
  std::fflush(file_);
}

}  // namespace aud_vst3
