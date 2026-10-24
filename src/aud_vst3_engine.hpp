// @license
// Copyright (c) Audanika. All Rights Reserved.
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

// The engine of the plugin: a graph with the build's node packages and its
// headless host (ticket 20, plugin-002) with the threads the host demands
// (tickets 24 and 37).
//
// - The realtime thread calls pushParam(), requestPreset(), render() and,
//   rendering offline, waitForParams() and waitForPreset(), nothing else.
//   The caller keeps every call of it out of the destructor's way
//   (Plugin::process and terminate).
// - One control thread per engine owns every [control] call of the graph
//   and the host: loading the document, applying presets, parameters and
//   notifications. aud_host_set_param is [control], so the parameter
//   changes the DAW hands to the processor travel through a lock-free ring
//   to the control thread, which wakes on a semaphore the realtime thread
//   posts. A change the graph's queue refuses waits on the control thread
//   and is passed on again; its value counts as current. A preset the DAW
//   asks for in a block travels the same way, newest request first.
// - Other threads hand tasks to the control thread with run() and wait.

#ifndef AUD_VST3_ENGINE_HPP
#define AUD_VST3_ENGINE_HPP

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

#include "aud_vst3_config.hpp"
#include "aud_vst3_settings.hpp"
#include "aud_vst3_sync.hpp"

namespace aud_vst3 {

// #############################################################################
// A parameter of the loaded document.
struct EngineParam {
  // ...........................................................................
  // The stable id: FNV-1a of "<node id>/<param id>".
  uint32_t id = 0;

  // ...........................................................................
  // The node id and the parameter id in the document.
  std::string nodeId;
  std::string paramId;

  // ...........................................................................
  // The name and the unit of the parameter's descriptor.
  std::string name;
  std::string unit;

  // ...........................................................................
  // The node handle, and the index of the parameter in the node's
  // descriptor.
  int32_t node = 0;
  uint32_t index = 0;

  // ...........................................................................
  // The range of the plain value, and the value the document sets.
  float min = 0;
  float max = 1;
  float defaultValue = 0;

  // ...........................................................................
  // The AUD_PARAM_* flags, and the steps of an AUD_PARAM_STEPPED one.
  uint32_t flags = 0;
  uint32_t steps = 0;
};

// #############################################################################
// What one render call hands the engine.
struct EngineBlock {
  float* const* outputs = nullptr;
  uint32_t channels = 0;
  uint32_t frames = 0;
  bool offline = false;
  const AudEvent* events = nullptr;
  uint32_t numEvents = 0;
  const AudTransportSnapshot* transport = nullptr;
};

// #############################################################################
// The graph, its host and the control thread that owns both; see above.
class Engine {
 public:
  // ...........................................................................
  // Starts the control thread.
  Engine();

  // ...........................................................................
  // Destroys the host and the graph on the control thread, then ends the
  // thread. No realtime call may be in flight.
  ~Engine();

  // ...........................................................................
  // Not copyable: the control thread works on this object.
  Engine(const Engine&) = delete;
  Engine& operator=(const Engine&) = delete;

  // ...........................................................................
  // [non-realtime] Creates the graph with the build's node packages and the
  // host, whose assets resolve against `baseDirectory`, and loads
  // `document`; false with `error` on a failure.
  bool open(const std::string& document, const std::string& baseDirectory,
            double sampleRate, uint32_t maxFrames, std::string* error);

  // ...........................................................................
  // The parameters of the loaded document, ordered by id. Stable after
  // open(): presets change values, never the nodes.
  const std::vector<EngineParam>& params() const { return params_; }

  // ...........................................................................
  // The parameter with the stable `id`, or null.
  const EngineParam* param(uint32_t id) const;

  // ...........................................................................
  // [non-realtime] Prepares the graph for a sample rate and a block size.
  bool prepare(double sampleRate, uint32_t maxFrames);

  // ...........................................................................
  // [non-realtime] Starts or stops rendering.
  bool setActive(bool active);

  // ...........................................................................
  // [non-realtime] The presets requestPreset() picks from, and what the
  // control thread calls after it applied one, with its index; set before
  // the first block, they stay.
  void setPresets(const std::vector<ShellPreset>* presets,
                  std::function<void(uint32_t)> applied);

  // ...........................................................................
  // [non-realtime] Applies `preset` now; false with `error` when a node
  // refused a part of it.
  bool applyPreset(const ShellPreset& preset, std::string* error);

  // ...........................................................................
  // [realtime] Asks the control thread to apply the preset at `index` of
  // setPresets(); a newer request replaces one not yet applied.
  void requestPreset(uint32_t index);

  // ...........................................................................
  // [non-realtime] The current plain value of a parameter.
  float value(uint32_t id);

  // ...........................................................................
  // [non-realtime] Sets a parameter on the control thread, e.g. from a
  // restored state.
  void setParam(uint32_t id, float plain);

  // ...........................................................................
  // [realtime] Hands a parameter change to the control thread.
  void pushParam(uint32_t id, float plain);

  // ...........................................................................
  // [realtime] Renders one block into planar output channels.
  void render(const EngineBlock& block) AUD_VST3_NONBLOCKING;

  // ...........................................................................
  // [offline rendering thread] Waits until the control thread has passed
  // on every change pushed so far, so that an offline block renders with
  // its changes, as playback does at the latest one block later. It may
  // block: offline rendering is not realtime.
  void waitForParams();

  // ...........................................................................
  // [offline rendering thread, non-realtime] Waits until the requested
  // preset is applied and the loads it started have ended, `timeoutMs` at
  // most; true when nothing is left.
  bool waitForPreset(uint32_t timeoutMs);

  // ...........................................................................
  // [non-realtime] The latency and the tail of the graph in frames.
  int32_t latency();
  uint32_t tail();

  // ...........................................................................
  // [non-realtime] Runs `task` on the control thread and waits for it.
  void run(const std::function<void()>& task);

  // ...........................................................................
  // The count of parameter changes the ring refused since the start.
  uint64_t droppedParams() const {
    return droppedParams_.load(std::memory_order_relaxed);
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
  void applyRequestedPreset();
  bool passOn(uint32_t id, float value);
  void takeNotifications();

  AudGraph* graph_ = nullptr;
  AudHost* host_ = nullptr;
  // The host as the realtime thread sees it, published by open().
  std::atomic<AudHost*> rtHost_{nullptr};
  std::vector<EngineParam> params_;
  uint32_t rampFrames_ = 0;

  // Realtime to control.
  AudSpscQueue<ParamChange> changes_;
  Semaphore wake_;
  std::atomic<uint64_t> droppedParams_{0};
  // The changes pushed, and those the control thread took from the ring
  // and passed on or parked; the control thread signals drained_ after
  // each pass, for waitForParams() and waitForPreset().
  std::atomic<uint64_t> pushed_{0};
  std::atomic<uint64_t> taken_{0};
  Semaphore drained_;
  // Changes the graph's queue refused, newest value per id (control thread
  // only).
  std::vector<ParamChange> parked_;

  // The presets and the preset the realtime thread asked for (-1: none),
  // with the count of requests and of those the control thread took.
  const std::vector<ShellPreset>* presets_ = nullptr;
  std::function<void(uint32_t)> presetApplied_;
  std::atomic<int32_t> requestedPreset_{-1};
  std::atomic<uint64_t> presetRequests_{0};
  std::atomic<uint64_t> presetsTaken_{0};

  // Tasks for the control thread.
  std::mutex mutex_;
  std::condition_variable done_;
  std::deque<std::function<void()>> tasks_;
  uint64_t tasksQueued_ = 0;
  uint64_t tasksDone_ = 0;
  bool stopping_ = false;
  int64_t lastNotificationsNs_ = 0;

  std::thread thread_;
};

}  // namespace aud_vst3

#endif  // AUD_VST3_ENGINE_HPP
