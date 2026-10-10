// @license
// Copyright (c) Audanika. All Rights Reserved.
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

#include "aud_vst3_engine.hpp"

#include <algorithm>
#include <cmath>
#include <cstring>

namespace aud_vst3 {

namespace {

// How often the control thread reads the meter and takes notifications.
constexpr int64_t kMeterPeriodNs = 33'000'000;

// How long the control thread sleeps when nothing wakes it.
constexpr int64_t kIdleWaitNs = 10'000'000;

// How long an offline block waits for the control thread at most.
constexpr int64_t kOfflineWaitNs = 100'000'000;

float clamp(const EngineParam& param, float value) {
  return std::min(param.max, std::max(param.min, value));
}

float finite(float value) { return std::isfinite(value) ? value : 0.0f; }

}  // namespace

Engine::Engine(Probe& probe)
    : probe_(probe),
      changes_(1024),
      wake_(dispatch_semaphore_create(0)),
      drained_(dispatch_semaphore_create(0)) {
  thread_ = std::thread([this] { loop(); });
}

Engine::~Engine() {
  // No realtime call is in flight: Plugin::terminate waits for process().
  rtHost_.store(nullptr, std::memory_order_relaxed);
  run([this] {
    if (graph_ != nullptr) {
      AudGraphStats stats{};
      stats.struct_size = sizeof(AudGraphStats);
      aud_graph_get_stats(graph_, &stats);
      probe_.write(
          "engineStats",
          "\"blocks\":" + std::to_string(stats.blocks_rendered) +
              ",\"overloads\":" + std::to_string(stats.overloads) +
              ",\"renderMaxNs\":" + std::to_string(stats.render_time_max_ns) +
              ",\"realtimeViolations\":" +
              std::to_string(stats.realtime_violations) + ",\"watchdog\":" +
              (aud_graph_watchdog_enabled() ? "true" : "false") +
              ",\"droppedParams\":" + std::to_string(droppedParams()) +
              ",\"refusedParams\":" + std::to_string(refusedParams()) +
              ",\"parkedParams\":" + std::to_string(parked_.size()));
      aud_graph_stop(graph_);
    }
    if (host_ != nullptr) aud_host_destroy(host_);
    if (graph_ != nullptr) aud_graph_destroy(graph_);
    host_ = nullptr;
    graph_ = nullptr;
  });
  {
    std::lock_guard<std::mutex> lock(mutex_);
    stopping_ = true;
  }
  dispatch_semaphore_signal(wake_);
  thread_.join();
  // A dispatch semaphore must not be released below its initial count.
  for (dispatch_semaphore_t semaphore : {wake_, drained_}) {
    while (dispatch_semaphore_wait(semaphore, DISPATCH_TIME_NOW) == 0) {
    }
    dispatch_release(semaphore);
  }
}

bool Engine::open(const std::string& document, double sampleRate,
                  uint32_t maxFrames, std::string* error) {
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
    host_ = aud_host_create(graph_, nullptr);
    if (host_ == nullptr) {
      if (error != nullptr) *error = "aud_host_create failed";
      return;
    }
    ok = loadOnControl(document, error);
    if (ok) collectParams();
  });
  if (ok) rtHost_.store(host_, std::memory_order_release);
  return ok;
}

bool Engine::prepare(double sampleRate, uint32_t maxFrames) {
  bool ok = false;
  run([&] {
    if (graph_ == nullptr) return;
    const bool running = aud_graph_state(graph_) == AUD_GRAPH_RUNNING;
    if (running) aud_graph_stop(graph_);
    ok = aud_graph_prepare(graph_, sampleRate, maxFrames) == AUD_OK;
    if (running) aud_graph_start(graph_);
  });
  return ok;
}

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

bool Engine::load(const std::string& document, std::string* error) {
  bool ok = false;
  run([&] {
    // Changes still waiting in the ring belong to the previous state.
    drainParams();
    ok = loadOnControl(document, error);
  });
  return ok;
}

std::string Engine::save() {
  std::string text;
  run([&] {
    if (host_ == nullptr) return;
    drainParams();
    size_t size = 0;
    if (aud_host_save(host_, nullptr, 0, &size) != AUD_ERROR_BUFFER_TOO_SMALL) {
      return;
    }
    text.resize(size + 1);
    if (aud_host_save(host_, &text[0], text.size(), &size) != AUD_OK) {
      text.clear();
      return;
    }
    text.resize(size);
  });
  return text;
}

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

EngineMeter Engine::meter() const {
  return {meterPeak_.load(std::memory_order_relaxed),
          meterRms_.load(std::memory_order_relaxed)};
}

void Engine::pushParam(uint32_t id, float plain, double normalized,
                       int32_t offset) {
  if (changes_.push({id, plain})) {
    pushed_.fetch_add(1, std::memory_order_release);
  } else {
    droppedParams_.fetch_add(1, std::memory_order_relaxed);
  }
  probe_.push({kProbeProcess, id, nowNs(), normalized, offset, 0});
  dispatch_semaphore_signal(wake_);
}

void Engine::waitForParams() {
  const uint64_t target = pushed_.load(std::memory_order_acquire);
  const int64_t deadline = nowNs() + kOfflineWaitNs;
  while (taken_.load(std::memory_order_acquire) < target && nowNs() < deadline) {
    dispatch_semaphore_signal(wake_);
    dispatch_semaphore_wait(drained_, dispatch_time(DISPATCH_TIME_NOW, 2'000'000));
  }
}

void Engine::render(float* const* outputs, uint32_t channels, uint32_t frames,
                    bool offline) {
  AudHost* host = rtHost_.load(std::memory_order_acquire);
  if (host == nullptr) {
    for (uint32_t c = 0; c < channels; ++c) {
      std::memset(outputs[c], 0, sizeof(float) * frames);
    }
    return;
  }
  // The changes the control thread passed on before this block starts; the
  // engine applies its parameter queue at the block start.
  const uint64_t passed = passed_.load(std::memory_order_acquire);
  AudAudioBus bus{sizeof(AudAudioBus), channels, outputs};
  AudRenderRequest request{};
  request.struct_size = sizeof(AudRenderRequest);
  request.frames = frames;
  request.num_output_buses = 1;
  request.outputs = &bus;
  AudHostRenderRequest hostRequest{};
  hostRequest.struct_size = sizeof(AudHostRenderRequest);
  hostRequest.flags = offline ? AUD_PROCESS_OFFLINE : 0;
  hostRequest.request = &request;
  aud_host_render(host, &hostRequest);
  if (passed != rendered_) {
    rendered_ = passed;
    probe_.push({kProbeRendered, 0, nowNs(), static_cast<double>(passed), 0,
                 0});
  }
}

void Engine::run(const std::function<void()>& task) {
  if (std::this_thread::get_id() == thread_.get_id()) {
    task();
    return;
  }
  std::unique_lock<std::mutex> lock(mutex_);
  tasks_.push_back(task);
  const uint64_t ticket = ++tasksQueued_;
  dispatch_semaphore_signal(wake_);
  done_.wait(lock, [&] { return tasksDone_ >= ticket; });
}

void Engine::loop() {
  for (;;) {
    dispatch_semaphore_wait(wake_,
                            dispatch_time(DISPATCH_TIME_NOW, kIdleWaitNs));
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
    const int64_t now = nowNs();
    if (now - lastMeterNs_ >= kMeterPeriodNs) {
      lastMeterNs_ = now;
      readMeter();
    }
    probe_.drain();
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
  meterNode_ = aud_host_node(host_, "meter");
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
    const auto it = std::find_if(
        params_.begin(), params_.end(),
        [&](const EngineParam& p) { return p.id == change.id; });
    if (it == params_.end()) continue;
    passOn(change.id, clamp(*it, change.plain));
  }
  if (taken > 0) {
    taken_.fetch_add(taken, std::memory_order_release);
    dispatch_semaphore_signal(drained_);
  }
}

// Hands one change to the host. The graph's queue refuses it while no block
// drains the queue (a host flushing parameters with empty process calls);
// then the change is parked, newest value per id, and passed on again with
// the next drain. aud_host_set_param keeps a refused value out of the
// host's table, so save() misses a change parked at that moment.
bool Engine::passOn(uint32_t id, float value) {
  if (aud_host_set_param(host_, id, value, 0) != AUD_OK) {
    refusedParams_.fetch_add(1, std::memory_order_relaxed);
    for (ParamChange& parked : parked_) {
      if (parked.id == id) {
        parked.plain = value;
        return false;
      }
    }
    parked_.push_back({id, value});
    return false;
  }
  const uint64_t sequence = passed_.fetch_add(1, std::memory_order_release) + 1;
  probe_.write("applied", "\"id\":" + std::to_string(id) +
                              ",\"plain\":" + probeNumber(value) +
                              ",\"sequence\":" + std::to_string(sequence));
  return true;
}

void Engine::readMeter() {
  if (graph_ == nullptr || meterNode_ <= 0) return;
  float peak = 0;
  float rms = 0;
  float peakRight = 0;
  float rmsRight = 0;
  aud_graph_tap_meter(graph_, meterNode_, 0, &peak, &rms);
  aud_graph_tap_meter(graph_, meterNode_, 1, &peakRight, &rmsRight);
  // A graph that blows up must not send NaN to the editors.
  meterPeak_.store(finite(std::max(peak, peakRight)), std::memory_order_relaxed);
  meterRms_.store(finite(std::max(rms, rmsRight)), std::memory_order_relaxed);
  AudGraphNotification notifications[32];
  for (auto& n : notifications) n.struct_size = sizeof(AudGraphNotification);
  while (aud_graph_take_notifications(graph_, notifications, 32) == 32) {
  }
}

}  // namespace aud_vst3
