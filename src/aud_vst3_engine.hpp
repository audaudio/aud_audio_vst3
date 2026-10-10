// @license
// Copyright (c) Audanika. All Rights Reserved.
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

// The engine of the spike plugin: a graph and its headless host (ticket 20,
// plugin-002) with the threads the host demands (ticket 24).
//
// - The realtime thread calls pushParam(), render() and, rendering
//   offline, waitForParams(), nothing else. The caller keeps every call of
//   it out of the destructor's way (Plugin::process and terminate).
// - One control thread per engine owns every [control] call of the graph
//   and the host: loading and saving the document, parameters, meters and
//   notifications. aud_host_set_param is [control], so the parameter
//   changes the plugin host hands to the processor travel through a
//   lock-free ring to the control thread, which wakes on a semaphore the
//   realtime thread posts. A change the graph's queue refuses waits on the
//   control thread and is passed on again; its value counts as current.
// - Other threads hand tasks to the control thread with run() and wait.

#ifndef AUD_VST3_ENGINE_HPP
#define AUD_VST3_ENGINE_HPP

#include <dispatch/dispatch.h>

#include <atomic>
#include <condition_variable>
#include <cstdint>
#include <deque>
#include <functional>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#include "aud_audio_graph.h"
#include "aud_spsc_queue.hpp"
#include "aud_vst3_probe.hpp"

namespace aud_vst3 {

// A parameter of the loaded document.
struct EngineParam {
  uint32_t id = 0;  // the stable id: FNV-1a of "<node id>/<param id>"
  std::string nodeId;
  std::string paramId;
  std::string name;
  std::string unit;
  int32_t node = 0;    // the node handle
  uint32_t index = 0;  // the index in the node's descriptor
  float min = 0;
  float max = 1;
  float defaultValue = 0;
  uint32_t flags = 0;  // AUD_PARAM_*
  uint32_t steps = 0;  // with AUD_PARAM_STEPPED
};

// The meter of the output.
struct EngineMeter {
  float peak = 0;
  float rms = 0;
};

class Engine {
 public:
  explicit Engine(Probe& probe);
  ~Engine();

  Engine(const Engine&) = delete;
  Engine& operator=(const Engine&) = delete;

  // [non-realtime] Creates the graph and the host on the control thread
  // and loads `document`; false with `error` on a failure.
  bool open(const std::string& document, double sampleRate,
            uint32_t maxFrames, std::string* error);

  // The parameters of the loaded document, ordered by id. Stable after
  // open(): every document the plugin loads has the same nodes.
  const std::vector<EngineParam>& params() const { return params_; }

  // [non-realtime] Prepares the graph for a sample rate and a block size.
  bool prepare(double sampleRate, uint32_t maxFrames);

  // [non-realtime] Starts or stops rendering.
  bool setActive(bool active);

  // [non-realtime] Loads a document saved by save(); false with `error`.
  bool load(const std::string& document, std::string* error);

  // [non-realtime] The current state as a document.
  std::string save();

  // [non-realtime] The current plain value of a parameter.
  float value(uint32_t id);

  // [non-realtime] The output meter as the control thread last read it.
  EngineMeter meter() const;

  // [realtime] Hands a parameter change to the control thread. `normalized`
  // is what the plugin host sent, for the probe.
  void pushParam(uint32_t id, float plain, double normalized, int32_t offset);

  // [realtime] Renders one block into planar output channels.
  void render(float* const* outputs, uint32_t channels, uint32_t frames,
              bool offline);

  // [offline rendering thread] Waits until the control thread has passed
  // on every change pushed so far, so that an offline block renders with
  // its changes, as playback does at the latest one block later. It may
  // block: offline rendering is not realtime.
  void waitForParams();

  // [non-realtime] Runs `task` on the control thread and waits for it.
  void run(const std::function<void()>& task);

  // The count of parameter changes the ring refused since the start.
  uint64_t droppedParams() const {
    return droppedParams_.load(std::memory_order_relaxed);
  }

  // The count of changes the graph's queue refused at first (and the
  // control thread passed on again) since the start.
  uint64_t refusedParams() const {
    return refusedParams_.load(std::memory_order_relaxed);
  }

 private:
  struct ParamChange {
    uint32_t id;
    float plain;
  };

  void loop();
  bool loadOnControl(const std::string& document, std::string* error);
  void collectParams();
  void drainParams();
  bool passOn(uint32_t id, float value);
  void readMeter();

  Probe& probe_;
  AudGraph* graph_ = nullptr;
  AudHost* host_ = nullptr;
  // The host as the realtime thread sees it, published by open().
  std::atomic<AudHost*> rtHost_{nullptr};
  int32_t meterNode_ = 0;
  std::vector<EngineParam> params_;

  // Realtime to control.
  AudSpscQueue<ParamChange> changes_;
  dispatch_semaphore_t wake_;
  std::atomic<uint64_t> droppedParams_{0};
  // The changes pushed, and those the control thread took from the ring
  // and passed on or parked; the control thread signals drained_ after
  // each pass, for waitForParams().
  std::atomic<uint64_t> pushed_{0};
  std::atomic<uint64_t> taken_{0};
  dispatch_semaphore_t drained_;
  // Changes the graph's queue refused, newest value per id (control thread
  // only), and how many were refused.
  std::vector<ParamChange> parked_;
  std::atomic<uint64_t> refusedParams_{0};
  // The changes the control thread passed on, and those a block has seen.
  std::atomic<uint64_t> passed_{0};
  uint64_t rendered_ = 0;  // realtime thread only

  // Tasks for the control thread.
  std::mutex mutex_;
  std::condition_variable done_;
  std::deque<std::function<void()>> tasks_;
  uint64_t tasksQueued_ = 0;
  uint64_t tasksDone_ = 0;
  bool stopping_ = false;

  std::atomic<float> meterPeak_{0};
  std::atomic<float> meterRms_{0};
  int64_t lastMeterNs_ = 0;

  std::thread thread_;
};

}  // namespace aud_vst3

#endif  // AUD_VST3_ENGINE_HPP
