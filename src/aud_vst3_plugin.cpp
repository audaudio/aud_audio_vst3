// @license
// Copyright (c) Audanika. All Rights Reserved.
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

#include "aud_vst3_plugin.hpp"

#include <algorithm>
#include <cstdlib>
#include <cstring>
#include <thread>

#include "aud_vst3_config.hpp"
#include "aud_vst3_skew.hpp"
#include "base/source/fstreamer.h"
#include "pluginterfaces/base/ibstream.h"
#include "pluginterfaces/base/ustring.h"
#include "pluginterfaces/vst/ivstparameterchanges.h"

namespace aud_vst3 {

using namespace Steinberg;
using namespace Steinberg::Vst;

namespace {

// The graph the spike plays: oscillator, filter and mixer, with a tap that
// feeds the meter of the editor.
const char* const kDocument = R"({
  "schema": 1,
  "name": "aud_audio_vst3 spike",
  "outputChannels": [2],
  "nodes": [
    { "id": "osc", "type": "aud.graph.oscillator",
      "preset": { "schema": 1, "type": "aud.graph.oscillator",
                  "params": { "frequency": 220, "amplitude": 0.2,
                              "waveform": 1 } } },
    { "id": "filter", "type": "aud.graph.filter",
      "preset": { "schema": 1, "type": "aud.graph.filter",
                  "params": { "cutoff": 1200, "resonance": 0.3,
                              "mode": 0 } } },
    { "id": "out", "type": "aud.graph.mixer",
      "inputChannels": [2, 2, 2, 2, 2, 2, 2, 2], "outputChannels": [2],
      "preset": { "schema": 1, "type": "aud.graph.mixer",
                  "params": { "master": 0.5 } } },
    { "id": "meter", "type": "aud.graph.tap" }
  ],
  "connections": [
    { "from": "osc", "to": "filter" },
    { "from": "filter", "to": "out" },
    { "from": "out", "to": "meter" },
    { "from": "meter", "to": "graph" }
  ]
})";

// The header of the plugin state: magic, version, length, then the
// document as JSON text.
constexpr uint32_t kStateMagic = 0x33445541;  // "AUD3"
constexpr uint32_t kStateVersion = 1;
// A document larger than this is refused as corrupt.
constexpr uint32_t kMaxStateLength = 16u << 20;

std::atomic<uint32_t> nextInstance{1};

constexpr double kDefaultSampleRate = 48000;
constexpr uint32_t kDefaultMaxFrames = 4096;

}  // namespace

uint32_t testParamId() {
  static const uint32_t id = aud_host_param_id("spike", "test");
  return id;
}

Plugin::Plugin()
    : instance_(nextInstance.fetch_add(1)),
      probe_(std::make_unique<Probe>(instance_)) {}

Plugin::~Plugin() = default;

FUnknown* Plugin::createInstance(void*) {
  return static_cast<IAudioProcessor*>(new Plugin());
}

std::string Plugin::bundledDocument() { return kDocument; }

tresult PLUGIN_API Plugin::initialize(FUnknown* context) {
  const tresult result = SingleComponentEffect::initialize(context);
  if (result != kResultOk) return result;
  skewOk_ = skewCheck();
#if AUD_VST3_RTSAN
  rtsanProbe_ = std::getenv("AUD_VST3_RTSAN_PROBE") != nullptr;
#endif
  probe_->write("init", std::string("\"variant\":\"") + kVariant +
                            "\",\"flavor\":" + std::to_string(kFlavor) +
                            ",\"hygiene\":" + (kHygiene ? "true" : "false") +
                            ",\"skewOk\":" + (skewOk_ ? "true" : "false"));
  probe_->startUiWatch();
  addAudioOutput(STR16("Stereo Out"), SpeakerArr::kStereo);
  addEventInput(STR16("Events"), 1);
  engine_ = std::make_unique<Engine>(*probe_);
  std::string error;
  if (!engine_->open(bundledDocument(), kDefaultSampleRate, kDefaultMaxFrames,
                     &error)) {
    probe_->write("error", "\"message\":\"" + error + "\"");
    return kResultFalse;
  }
  for (const EngineParam& param : engine_->params()) {
    auto* parameter = new AudParameter(param);
    parameters.addParameter(parameter);
    mappings_.push_back(parameter->mapping());
  }
  std::sort(mappings_.begin(), mappings_.end(),
            [](const ParamMapping& a, const ParamMapping& b) {
              return a.id < b.id;
            });
  parameters.addParameter(STR16("Spike test"), nullptr, 1, 0,
                          ParameterInfo::kNoFlags, testParamId());
  rtEngine_.store(engine_.get(), std::memory_order_release);
  return kResultOk;
}

tresult PLUGIN_API Plugin::terminate() {
  // Sequentially consistent, as in process(): each side stores, then loads
  // what the other stores, which acquire and release alone may reorder.
  rtEngine_.store(nullptr, std::memory_order_seq_cst);
  while (processing_.load(std::memory_order_seq_cst) != 0) {
    std::this_thread::yield();
  }
  probe_->stopUiWatch();
  for (auto& entry : openEdits_) {
    for (const uint32_t id : entry.second) endEdit(id);
  }
  openEdits_.clear();
  editorState_.reset();
  observers_.clear();
  engine_.reset();
  return SingleComponentEffect::terminate();
}

tresult PLUGIN_API Plugin::setActive(TBool state) {
  return engine_ != nullptr && engine_->setActive(state != 0) ? kResultOk
                                                              : kResultFalse;
}

tresult PLUGIN_API Plugin::setState(IBStream* state) {
  if (state == nullptr || engine_ == nullptr) return kInvalidArgument;
  IBStreamer streamer(state, kLittleEndian);
  uint32 magic = 0;
  uint32 version = 0;
  uint32 length = 0;
  if (!streamer.readInt32u(magic) || magic != kStateMagic ||
      !streamer.readInt32u(version) || version != kStateVersion ||
      !streamer.readInt32u(length) || length > kMaxStateLength) {
    return kResultFalse;
  }
  std::string document(length, '\0');
  if (length > 0 && streamer.readRaw(&document[0], length) !=
                        static_cast<TSize>(length)) {
    return kResultFalse;
  }
  std::string error;
  if (!engine_->load(document, &error)) {
    probe_->write("error", "\"message\":\"setState\"");
    return kResultFalse;
  }
  for (const EngineParam& param : engine_->params()) {
    const ParamMapping* m = mapping(param.id);
    if (m == nullptr) continue;
    const double value = m->toNormalized(engine_->value(param.id));
    EditControllerEx1::setParamNormalized(param.id, value);
    for (ParamObserver* observer : observers_) {
      observer->paramChanged(param.id, value);
    }
  }
  return kResultOk;
}

tresult PLUGIN_API Plugin::getState(IBStream* state) {
  if (state == nullptr || engine_ == nullptr) return kInvalidArgument;
  const std::string document = engine_->save();
  if (document.empty()) return kResultFalse;
  IBStreamer streamer(state, kLittleEndian);
  streamer.writeInt32u(kStateMagic);
  streamer.writeInt32u(kStateVersion);
  streamer.writeInt32u(static_cast<uint32>(document.size()));
  streamer.writeRaw(document.data(), static_cast<int32>(document.size()));
  return kResultOk;
}

tresult PLUGIN_API Plugin::setBusArrangements(SpeakerArrangement* inputs,
                                              int32 numIns,
                                              SpeakerArrangement* outputs,
                                              int32 numOuts) {
  (void)inputs;
  if (numIns == 0 && numOuts == 1 && outputs[0] == SpeakerArr::kStereo) {
    return SingleComponentEffect::setBusArrangements(inputs, numIns, outputs,
                                                     numOuts);
  }
  return kResultFalse;
}

tresult PLUGIN_API Plugin::canProcessSampleSize(int32 symbolicSampleSize) {
  return symbolicSampleSize == kSample32 ? kResultTrue : kResultFalse;
}

tresult PLUGIN_API Plugin::setupProcessing(ProcessSetup& setup) {
  if (engine_ == nullptr || setup.symbolicSampleSize != kSample32) {
    return kResultFalse;
  }
  if (!engine_->prepare(setup.sampleRate,
                        static_cast<uint32_t>(setup.maxSamplesPerBlock))) {
    return kResultFalse;
  }
  return SingleComponentEffect::setupProcessing(setup);
}

tresult PLUGIN_API Plugin::setProcessing(TBool) { return kResultOk; }

const ParamMapping* Plugin::mapping(uint32_t id) const {
  const auto it = std::lower_bound(
      mappings_.begin(), mappings_.end(), id,
      [](const ParamMapping& m, uint32_t value) { return m.id < value; });
  return it != mappings_.end() && it->id == id ? &*it : nullptr;
}

tresult PLUGIN_API Plugin::process(ProcessData& data) {
  processing_.fetch_add(1, std::memory_order_seq_cst);
  Engine* engine = rtEngine_.load(std::memory_order_seq_cst);
  if (engine != nullptr) {
    pushChanges(data, *engine);
    // Offline the block waits for its changes; the realtime path never
    // waits (pushChanges and renderBlock are nonblocking).
    if (data.processMode == kOffline) engine->waitForParams();
    renderBlock(data, *engine);
  }
  processing_.fetch_sub(1, std::memory_order_release);
  return engine != nullptr ? kResultOk : kResultFalse;
}

void Plugin::pushChanges(ProcessData& data, Engine& engine) AUD_VST3_NONBLOCKING {
#if AUD_VST3_RTSAN
  // The proof that the sanitizer watches this thread: one allocation when
  // AUD_VST3_RTSAN_PROBE is set; the run must abort with a report.
  if (rtsanProbe_) {
    rtsanProbe_ = false;
    // Through a volatile pointer: the compiler may not elide it.
    void* (*volatile allocate)(size_t) = &std::malloc;
    std::free(allocate(16));
  }
#endif
  if (IParameterChanges* changes = data.inputParameterChanges) {
    const int32 count = changes->getParameterCount();
    for (int32 i = 0; i < count; ++i) {
      IParamValueQueue* queue = changes->getParameterData(i);
      if (queue == nullptr) continue;
      const int32 points = queue->getPointCount();
      int32 offset = 0;
      ParamValue value = 0;
      if (points <= 0 ||
          queue->getPoint(points - 1, offset, value) != kResultTrue) {
        continue;
      }
      const ParamMapping* m = mapping(queue->getParameterId());
      if (m == nullptr) continue;
      engine.pushParam(m->id, m->toPlain(value), value, offset);
    }
  }
}

void Plugin::renderBlock(ProcessData& data, Engine& engine) AUD_VST3_NONBLOCKING {
  if (data.numSamples <= 0 || data.numOutputs < 1 ||
      data.outputs[0].numChannels <= 0) {
    return;
  }
  engine.render(data.outputs[0].channelBuffers32,
                  static_cast<uint32_t>(data.outputs[0].numChannels),
                  static_cast<uint32_t>(data.numSamples),
                  data.processMode == kOffline);
  data.outputs[0].silenceFlags = 0;
}

uint32 PLUGIN_API Plugin::getLatencySamples() { return 0; }

uint32 PLUGIN_API Plugin::getTailSamples() { return kNoTail; }

IPlugView* PLUGIN_API Plugin::createView(FIDString name) {
  if (name == nullptr || std::strcmp(name, ViewType::kEditor) != 0) {
    return nullptr;
  }
  return createEditorView(this);
}

tresult PLUGIN_API Plugin::setParamNormalized(ParamID tag, ParamValue value) {
  const tresult result = EditControllerEx1::setParamNormalized(tag, value);
  if (tag == testParamId()) {
    const bool on = value > 0.5;
    if (on && !testRunning_) {
      for (ParamObserver* observer : observers_) observer->testRequested();
    }
    testRunning_ = on;
    return result;
  }
  probe_->write("hostParam", "\"id\":" + std::to_string(tag) +
                                 ",\"value\":" + probeNumber(value));
  for (ParamObserver* observer : observers_) {
    observer->paramChanged(tag, value);
  }
  return result;
}

const std::vector<EngineParam>& Plugin::params() const {
  static const std::vector<EngineParam> none;
  return engine_ != nullptr ? engine_->params() : none;
}

void Plugin::editBegin(uint32_t id, const void* owner) {
  if (openEdits_[owner].insert(id).second) beginEdit(id);
}

void Plugin::edit(uint32_t id, double normalized, int64_t inputStamp,
                  ParamObserver* origin) {
  EditControllerEx1::setParamNormalized(id, normalized);
  probe_->write("edit", "\"id\":" + std::to_string(id) + ",\"value\":" +
                            probeNumber(normalized) +
                            ",\"input\":" + std::to_string(inputStamp));
  performEdit(id, normalized);
  for (ParamObserver* observer : observers_) {
    if (observer != origin) observer->paramChanged(id, normalized);
  }
}

void Plugin::editEnd(uint32_t id, const void* owner) {
  const auto it = openEdits_.find(owner);
  if (it == openEdits_.end() || it->second.erase(id) == 0) return;
  if (it->second.empty()) openEdits_.erase(it);
  endEdit(id);
}

void Plugin::endEdits(const void* owner) {
  const auto it = openEdits_.find(owner);
  if (it == openEdits_.end()) return;
  const std::set<uint32_t> ids = it->second;
  openEdits_.erase(it);
  for (const uint32_t id : ids) endEdit(id);
}

void Plugin::addObserver(ParamObserver* observer) {
  observers_.push_back(observer);
}

void Plugin::removeObserver(ParamObserver* observer) {
  observers_.erase(std::remove(observers_.begin(), observers_.end(), observer),
                   observers_.end());
}

double Plugin::normalized(uint32_t id) { return getParamNormalized(id); }

#if AUD_VST3_VARIANT == 'D'
IPlugView* createEditorView(Plugin*) { return nullptr; }
#endif

}  // namespace aud_vst3
