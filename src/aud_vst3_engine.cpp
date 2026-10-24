// @license
// Copyright (c) Audanika. All Rights Reserved.
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

#include "aud_vst3_engine.hpp"

#include <algorithm>
#include <cmath>
#include <cstring>

#include "aud_clock.h"

#include "aud_vst3_bundle.hpp"
#include "aud_vst3_packages.hpp"

namespace aud_vst3 {

namespace {

// How often the control thread takes the graph's notifications.
constexpr int64_t kNotificationPeriodNs = 33'000'000;

// How long the control thread sleeps when nothing wakes it.
constexpr int64_t kIdleWaitNs = 10'000'000;

// How long an offline block waits for the control thread at most.
constexpr int64_t kOfflineWaitNs = 100'000'000;

// How long an offline block waits for one pass of the control thread
// before it wakes the thread again.
constexpr int64_t kOfflinePassNs = 2'000'000;

// The ramp of a parameter change, in seconds: long enough that automation
// steps at block boundaries do not click, short enough to follow it.
constexpr double kRampSeconds = 0.005;

float clamp(const EngineParam& param, float value) {
  return std::min(param.max, std::max(param.min, value));
}

}  // namespace

// #############################################################################
// Engine

// .............................................................................
Engine::Engine()
    : changes_(1024) {
  thread_ = std::thread([this] { loop(); });
}

// .............................................................................
Engine::~Engine() {
  // No realtime call is in flight: Plugin::terminate waits for process().
  rtHost_.store(nullptr, std::memory_order_relaxed);
  run([this] {
    if (graph_ != nullptr) aud_graph_stop(graph_);
    if (host_ != nullptr) aud_host_destroy(host_);
    if (graph_ != nullptr) aud_graph_destroy(graph_);
    host_ = nullptr;
    graph_ = nullptr;
  });
  {
    std::lock_guard<std::mutex> lock(mutex_);
    stopping_ = true;
  }
  wake_.post();
  thread_.join();
}

// .............................................................................
bool Engine::open(const std::string& document, const std::string& baseDirectory,
                  double sampleRate, uint32_t maxFrames, std::string* error) {
  bool ok = false;
  run([&] {
    const uint32_t outputChannels[] = {2};
    AudGraphConfig config{};
    config.struct_size = sizeof(AudGraphConfig);
    config.sample_rate = sampleRate;
    config.max_frames = maxFrames;
    config.num_output_buses = 1;
    config.output_channels = outputChannels;
    graph_ = aud_graph_create(&config);
    if (graph_ == nullptr) {
      if (error != nullptr) *error = "aud_graph_create failed";
      return;
    }
    if (!registerPackages(graph_, error)) return;
    AudHostOptions options{};
    options.struct_size = sizeof(AudHostOptions);
    options.base_directory = baseDirectory.empty() ? nullptr : baseDirectory.c_str();
    host_ = aud_host_create(graph_, &options);
    if (host_ == nullptr) {
      if (error != nullptr) *error = "aud_host_create failed";
      return;
    }
    rampFrames_ = static_cast<uint32_t>(std::lround(sampleRate * kRampSeconds));
    ok = loadOnControl(document, error);
    if (ok) collectParams();
  });
  if (ok) rtHost_.store(host_, std::memory_order_release);
  return ok;
}

// .............................................................................
const EngineParam* Engine::param(uint32_t id) const {
  const auto it = std::lower_bound(
      params_.begin(), params_.end(), id,
      [](const EngineParam& p, uint32_t value) { return p.id < value; });
  return it != params_.end() && it->id == id ? &*it : nullptr;
}

// .............................................................................
bool Engine::prepare(double sampleRate, uint32_t maxFrames) {
  bool ok = false;
  run([&] {
    if (graph_ == nullptr) return;
    const bool running = aud_graph_state(graph_) == AUD_GRAPH_RUNNING;
    if (running) aud_graph_stop(graph_);
    ok = aud_graph_prepare(graph_, sampleRate, maxFrames) == AUD_OK;
    rampFrames_ = static_cast<uint32_t>(std::lround(sampleRate * kRampSeconds));
    if (running) aud_graph_start(graph_);
  });
  return ok;
}

// .............................................................................
bool Engine::setActive(bool active) {
  bool ok = false;
  run([&] {
    if (graph_ == nullptr) return;
    const int32_t state = aud_graph_state(graph_);
    if (active) {
      ok = state == AUD_GRAPH_RUNNING || aud_graph_start(graph_) == AUD_OK;
    } else {
      ok = state != AUD_GRAPH_RUNNING || aud_graph_stop(graph_) == AUD_OK;
    }
  });
  return ok;
}

// .............................................................................
void Engine::setPresets(const std::vector<ShellPreset>* presets,
                        std::function<void(uint32_t)> applied) {
  run([&] {
    presets_ = presets;
    presetApplied_ = std::move(applied);
  });
}

// .............................................................................
bool Engine::applyPreset(const ShellPreset& preset, std::string* error) {
  bool ok = true;
  run([&] {
    if (host_ == nullptr) {
      ok = false;
      return;
    }
    for (const auto& [node, json] : preset.nodes) {
      if (aud_host_apply_preset(host_, node.c_str(), json.data(), json.size()) !=
          AUD_OK) {
        // The other nodes still take their part: a sound with one node
        // missing beats a mix of two presets.
        ok = false;
        if (error != nullptr) {
          *error = "preset " + preset.id + ", node " + node + ": " +
                   aud_host_last_error(host_);
        }
      }
    }
  });
  return ok;
}

// .............................................................................
void Engine::requestPreset(uint32_t index) {
  requestedPreset_.store(static_cast<int32_t>(index), std::memory_order_relaxed);
  presetRequests_.fetch_add(1, std::memory_order_release);
  wake_.post();
}

// .............................................................................
float Engine::value(uint32_t id) {
  float result = 0;
  run([&] {
    drainParams();
    if (host_ != nullptr) aud_host_get_param(host_, id, &result);
    // A parked change is newer than what the host holds.
    for (const ParamChange& change : parked_) {
      if (change.id == id) result = change.plain;
    }
  });
  return result;
}

// .............................................................................
void Engine::setParam(uint32_t id, float plain) {
  run([&] {
    if (host_ == nullptr) return;
    drainParams();
    if (const EngineParam* p = param(id)) passOn(id, clamp(*p, plain));
  });
}

// .............................................................................
void Engine::pushParam(uint32_t id, float plain) {
  if (changes_.push({id, plain})) {
    pushed_.fetch_add(1, std::memory_order_release);
  } else {
    droppedParams_.fetch_add(1, std::memory_order_relaxed);
  }
  wake_.post();
}

// .............................................................................
void Engine::waitForParams() {
  const uint64_t target = pushed_.load(std::memory_order_acquire);
  const int64_t deadline = aud_clock_now_ns() + kOfflineWaitNs;
  while (taken_.load(std::memory_order_acquire) < target &&
         aud_clock_now_ns() < deadline) {
    wake_.post();
    drained_.waitFor(kOfflinePassNs);
  }
}

// .............................................................................
bool Engine::waitForPreset(uint32_t timeoutMs) {
  const uint64_t target = presetRequests_.load(std::memory_order_acquire);
  const int64_t deadline =
      aud_clock_now_ns() + static_cast<int64_t>(timeoutMs) * 1'000'000;
  while (presetsTaken_.load(std::memory_order_acquire) < target &&
         aud_clock_now_ns() < deadline) {
    wake_.post();
    drained_.waitFor(kOfflinePassNs);
  }
  const int64_t left = (deadline - aud_clock_now_ns()) / 1'000'000;
  int32_t result = AUD_PENDING;
  if (left > 0) {
    run([&] {
      if (host_ != nullptr) {
        result = aud_host_wait_loads(host_, static_cast<uint32_t>(left));
      }
    });
  }
  return result == AUD_OK &&
         presetsTaken_.load(std::memory_order_acquire) >= target;
}

// .............................................................................
int32_t Engine::latency() {
  int32_t result = 0;
  run([&] {
    if (host_ != nullptr) result = std::max(0, aud_host_latency(host_));
  });
  return result;
}

// .............................................................................
uint32_t Engine::tail() {
  uint32_t result = 0;
  run([&] {
    if (host_ != nullptr) result = aud_host_tail(host_);
  });
  return result;
}

// .............................................................................
void Engine::render(const EngineBlock& block) AUD_VST3_NONBLOCKING {
  AudHost* host = rtHost_.load(std::memory_order_acquire);
  if (host == nullptr) {
    for (uint32_t c = 0; c < block.channels; ++c) {
      std::memset(block.outputs[c], 0, sizeof(float) * block.frames);
    }
    return;
  }
  AudAudioBus bus{sizeof(AudAudioBus), block.channels, block.outputs};
  AudRenderRequest request{};
  request.struct_size = sizeof(AudRenderRequest);
  request.frames = block.frames;
  request.num_output_buses = 1;
  request.outputs = &bus;
  request.num_events = block.numEvents;
  request.events = block.events;
  request.transport = block.transport;
  AudHostRenderRequest hostRequest{};
  hostRequest.struct_size = sizeof(AudHostRenderRequest);
  hostRequest.flags = block.offline ? AUD_PROCESS_OFFLINE : 0;
  hostRequest.request = &request;
  aud_host_render(host, &hostRequest);
}

// .............................................................................
void Engine::run(const std::function<void()>& task) {
  if (std::this_thread::get_id() == thread_.get_id()) {
    task();
    return;
  }
  std::unique_lock<std::mutex> lock(mutex_);
  tasks_.push_back(task);
  const uint64_t ticket = ++tasksQueued_;
  wake_.post();
  done_.wait(lock, [&] { return tasksDone_ >= ticket; });
}

void Engine::loop() {
  for (;;) {
    wake_.waitFor(kIdleWaitNs);
    std::deque<std::function<void()>> tasks;
    {
      std::lock_guard<std::mutex> lock(mutex_);
      if (stopping_ && tasks_.empty()) break;
      tasks.swap(tasks_);
    }
    for (const auto& task : tasks) task();
    if (!tasks.empty()) {
      std::lock_guard<std::mutex> lock(mutex_);
      tasksDone_ += tasks.size();
      done_.notify_all();
    }
    drainParams();
    applyRequestedPreset();
    const int64_t now = aud_clock_now_ns();
    if (now - lastNotificationsNs_ >= kNotificationPeriodNs) {
      lastNotificationsNs_ = now;
      takeNotifications();
    }
  }
}

bool Engine::loadOnControl(const std::string& document, std::string* error) {
  if (host_ == nullptr) return false;
  const int32_t result = aud_host_load(host_, document.data(), document.size());
  if (result != AUD_OK) {
    if (error != nullptr) {
      *error = std::string("aud_host_load: ") + aud_host_last_error(host_);
    }
    return false;
  }
  return true;
}

void Engine::collectParams() {
  params_.clear();
  const int32_t count = aud_host_num_params(host_);
  for (int32_t i = 0; i < count; ++i) {
    AudHostParam param{};
    param.struct_size = sizeof(AudHostParam);
    if (aud_host_param(host_, static_cast<uint32_t>(i), &param) != AUD_OK) {
      continue;
    }
    const AudParamDescriptor* d = param.descriptor;
    EngineParam entry;
    entry.id = param.id;
    entry.nodeId = param.node_id;
    entry.paramId = param.param_id;
    entry.name = d->name != nullptr ? d->name : param.param_id;
    entry.unit = d->unit != nullptr ? d->unit : "";
    entry.node = param.node;
    entry.index = param.index;
    entry.min = d->min_value;
    entry.max = d->max_value;
    entry.defaultValue = param.value;
    entry.flags = d->flags;
    entry.steps = d->steps;
    params_.push_back(entry);
  }
  std::sort(params_.begin(), params_.end(),
            [](const EngineParam& a, const EngineParam& b) { return a.id < b.id; });
}

void Engine::drainParams() {
  if (host_ == nullptr) return;
  // Parked changes first: they are older than the ring's.
  std::vector<ParamChange> parked;
  parked.swap(parked_);
  for (const ParamChange& change : parked) passOn(change.id, change.plain);
  ParamChange change{};
  uint64_t taken = 0;
  while (changes_.pop(change)) {
    ++taken;
    const EngineParam* p = param(change.id);
    if (p == nullptr) continue;
    passOn(change.id, clamp(*p, change.plain));
  }
  if (taken > 0) {
    taken_.fetch_add(taken, std::memory_order_release);
    drained_.post();
  }
}

void Engine::applyRequestedPreset() {
  const uint64_t requests = presetRequests_.load(std::memory_order_acquire);
  if (presetsTaken_.load(std::memory_order_relaxed) >= requests) return;
  const int32_t index = requestedPreset_.exchange(-1, std::memory_order_relaxed);
  if (index >= 0 && presets_ != nullptr &&
      static_cast<size_t>(index) < presets_->size()) {
    std::string error;
    if (!applyPreset((*presets_)[static_cast<size_t>(index)], &error)) {
      logError(error);
    }
    if (presetApplied_) presetApplied_(static_cast<uint32_t>(index));
  }
  presetsTaken_.store(requests, std::memory_order_release);
  drained_.post();
}

// Hands one change to the host. The graph's queue refuses it while no block
// drains the queue (a host flushing parameters with empty process calls);
// then the change is parked, newest value per id, and passed on again with
// the next drain.
bool Engine::passOn(uint32_t id, float value) {
  if (aud_host_set_param(host_, id, value, rampFrames_) != AUD_OK) {
    for (ParamChange& parked : parked_) {
      if (parked.id == id) {
        parked.plain = value;
        return false;
      }
    }
    parked_.push_back({id, value});
    return false;
  }
  return true;
}

void Engine::takeNotifications() {
  if (graph_ == nullptr) return;
  AudGraphNotification notifications[32];
  for (auto& n : notifications) n.struct_size = sizeof(AudGraphNotification);
  while (aud_graph_take_notifications(graph_, notifications, 32) == 32) {
  }
}

}  // namespace aud_vst3
