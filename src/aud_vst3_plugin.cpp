// @license
// Copyright (c) Audanika. All Rights Reserved.
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

#include "aud_vst3_plugin.hpp"

#include <dispatch/dispatch.h>

#include <algorithm>
#include <cmath>
#include <cstring>
#include <thread>
#include <utility>

#include "base/source/fstreamer.h"
#include "pluginterfaces/base/ibstream.h"
#include "pluginterfaces/vst/ivstevents.h"
#include "pluginterfaces/vst/ivstmidicontrollers.h"
#include "pluginterfaces/vst/ivstparameterchanges.h"
#include "pluginterfaces/vst/ivstprocesscontext.h"

#include "aud_vst3_bundle.hpp"
#include "aud_vst3_midi.hpp"
#include "aud_vst3_packages.hpp"

namespace aud_vst3 {

using namespace Steinberg;
using namespace Steinberg::Vst;

namespace {

// The header of the plugin state: magic, version, length, then the state
// as JSON text. Version 1 was the spike's graph document, which the shell
// refuses.
constexpr uint32_t kStateMagic = 0x33445541;  // "AUD3"
constexpr uint32_t kStateVersion = 2;
// A state larger than this is refused as corrupt.
constexpr uint32_t kMaxStateLength = 1u << 20;

constexpr double kDefaultSampleRate = 48000;
constexpr uint32_t kDefaultMaxFrames = 4096;

// How long an offline block waits at most for a preset to load.
constexpr uint32_t kOfflineLoadMs = 30'000;

// What the control thread hands the UI thread after a preset applied: the
// new values of the parameters the DAW sees.
struct PresetValues {
  Plugin* plugin;
  std::shared_ptr<bool> alive;
  uint32_t preset;
  double presetNormalized;
  std::vector<std::pair<uint32_t, double>> values;
};

std::atomic<uint32_t> nextInstance{1};

std::string titleOf(uint32_t channel, uint32_t controller) {
  const std::string suffix = " (channel " + std::to_string(channel + 1) + ")";
  if (controller == kMidiPitchBend) return "Pitch Bend" + suffix;
  if (controller == kMidiChannelPressure) return "Channel Pressure" + suffix;
  return "CC " + std::to_string(controller) + suffix;
}

}  // namespace

// #############################################################################
uint32_t presetParamId() {
  static const uint32_t id = aud_host_param_id("shell", "preset");
  return id;
}

// #############################################################################
// Plugin

// .............................................................................
Plugin::Plugin() : instance_(nextInstance.fetch_add(1)), clock_(true) {}

// .............................................................................
Plugin::~Plugin() = default;

// .............................................................................
FUnknown* Plugin::createInstance(void*) {
  return static_cast<IAudioProcessor*>(new Plugin());
}

tresult PLUGIN_API Plugin::initialize(FUnknown* context) {
  const tresult result = SingleComponentEffect::initialize(context);
  if (result != kResultOk) return result;
  std::string error;
  const std::string directory = settingsDirectory();
  if (!readSettings(directory, &settings_, &error)) {
    logError("The plugin's settings do not read: " + error);
    return kResultFalse;
  }
  std::string content;
  if (!settings_.content.empty()) {
    content = contentDirectory(settings_.content, resolvedBundlePath());
    if (content.empty()) {
      logError("The content of " + settings_.name + " is missing");
      return kResultFalse;
    }
  }
  clock_ = TransportClock(settings_.freeRunningTransport);
  setVoiceBudget(settings_.voiceBudget);
  addAudioOutput(STR16("Stereo Out"), SpeakerArr::kStereo);
  addEventInput(STR16("MIDI In"), kMidiChannels);
  // What the editor plays goes to the DAW, which records it on a MIDI track.
  addEventOutput(STR16("MIDI Out"), kMidiChannels);
  engine_ = std::make_unique<Engine>();
  if (!engine_->open(settings_.document, content, kDefaultSampleRate,
                     kDefaultMaxFrames, &error)) {
    logError("The document of " + settings_.name + " does not load: " + error);
    engine_.reset();
    return kResultFalse;
  }
  // The callback runs on the engine's control thread, also while the engine
  // is destroyed, when engine_ is null already.
  Engine* engine = engine_.get();
  engine_->setPresets(&settings_.presets, [this, engine](uint32_t index) {
    presetApplied(*engine, index);
  });
  preset_.store(static_cast<int32_t>(settings_.defaultPreset));
  addParameters();
  addMidiParameters();
  rtEngine_.store(engine_.get(), std::memory_order_release);
  logInfo(settings_.name + " is ready, content in " + content);
  return kResultOk;
}

void Plugin::addParameters() {
  // The presets: the program list of the root unit and its stepped
  // parameter, which a DAW automates like any other.
  const auto listId = static_cast<ProgramListID>(presetParamId());
  addUnit(new Unit(STR16("Root"), kRootUnitId, kNoParentUnitId, listId));
  auto* list = new ProgramList(STR16("Presets"), listId, kRootUnitId);
  for (const ShellPreset& preset : settings_.presets) {
    String128 name;
    writeUtf16(preset.name, name, 128);
    list->addProgram(name);
  }
  addProgramList(list);
  Parameter* presets = list->getParameter();
  presets->getInfo().flags =
      ParameterInfo::kIsProgramChange | ParameterInfo::kIsList |
      ParameterInfo::kCanAutomate;
  const int32 steps = presets->getInfo().stepCount;
  presets->getInfo().defaultNormalizedValue =
      steps > 0 ? static_cast<double>(settings_.defaultPreset) / steps : 0;
  presets->setNormalized(presets->getInfo().defaultNormalizedValue);
  parameters.addParameter(presets);

  for (const ShellParam& shellParam : settings_.params) {
    const EngineParam* param = engine_->param(shellParam.id);
    if (param == nullptr) {
      logError("The document has no parameter " + shellParam.node + "/" +
               shellParam.param);
      continue;
    }
    auto* parameter = new AudParameter(*param, shellParam.name);
    parameter->getInfo().flags |= ParameterInfo::kCanAutomate;
    parameters.addParameter(parameter);
    mappings_.push_back(parameter->mapping());
  }
  std::sort(mappings_.begin(), mappings_.end(),
            [](const ParamMapping& a, const ParamMapping& b) {
              return a.id < b.id;
            });

  controlValues_ =
      std::make_unique<std::atomic<float>[]>(settings_.controls.size());
  for (size_t i = 0; i < settings_.controls.size(); ++i) {
    const ShellControl& control = settings_.controls[i];
    String128 title;
    writeUtf16(control.name, title, 128);
    parameters.addParameter(title, nullptr, 0, control.defaultValue,
                            ParameterInfo::kCanAutomate, control.paramId);
    controlIds_.push_back(control.paramId);
    // Untouched: a control sends nothing until it moves, so that what the
    // preset sets - e.g. the start values of a combi's scripts - holds.
    controlValues_[i].store(std::nanf(""));
  }
}

void Plugin::addMidiParameters() {
  midiParams_.assign(kMidiChannels * kMidiControllers, false);
  for (uint32_t channel = 0; channel < kMidiChannels; ++channel) {
    for (uint32_t controller = 0; controller < kMidiControllers; ++controller) {
      const uint32_t id = midiParamId(channel, controller);
      // A graph parameter whose stable id falls here keeps it.
      if (parameters.getParameter(id) != nullptr) continue;
      String128 title;
      writeUtf16(titleOf(channel, controller), title, 128);
      parameters.addParameter(title, nullptr, 0,
                              controller == kMidiPitchBend ? 0.5 : 0,
                              ParameterInfo::kIsHidden, id);
      midiParams_[channel * kMidiControllers + controller] = true;
    }
  }
}

tresult PLUGIN_API Plugin::terminate() {
  // Sequentially consistent, as in process(): each side stores, then loads
  // what the other stores, which acquire and release alone may reorder.
  rtEngine_.store(nullptr, std::memory_order_seq_cst);
  while (processing_.load(std::memory_order_seq_cst) != 0) {
    std::this_thread::yield();
  }
  *alive_ = false;
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

// [control thread] A preset applied: the parameters the DAW sees take its
// values on the UI thread, and the DAW hears that they changed.
void Plugin::presetApplied(Engine& engine, uint32_t index) {
  auto* values = new PresetValues{this, alive_, index, 0, {}};
  const size_t count = settings_.presets.size();
  values->presetNormalized =
      count > 1 ? static_cast<double>(index) / static_cast<double>(count - 1)
                : 0;
  for (const ParamMapping& m : mappings_) {
    values->values.emplace_back(m.id, m.toNormalized(engine.value(m.id)));
  }
  dispatch_async_f(dispatch_get_main_queue(), values, [](void* context) {
    std::unique_ptr<PresetValues> values(static_cast<PresetValues*>(context));
    if (!*values->alive) return;
    Plugin* plugin = values->plugin;
    plugin->EditControllerEx1::setParamNormalized(presetParamId(),
                                                   values->presetNormalized);
    for (const auto& [id, value] : values->values) {
      plugin->EditControllerEx1::setParamNormalized(id, value);
      for (PluginObserver* observer : plugin->observers_) {
        observer->paramChanged(id, value);
      }
    }
    plugin->notifyPreset(values->preset);
    if (IComponentHandler* handler = plugin->getComponentHandler()) {
      handler->restartComponent(kParamValuesChanged);
    }
  });
}

int32_t Plugin::presetOf(double normalized) const {
  const size_t count = settings_.presets.size();
  if (count == 0) return -1;
  const double clamped = std::min(1.0, std::max(0.0, normalized));
  return static_cast<int32_t>(
      std::lround(clamped * static_cast<double>(count - 1)));
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
  std::string text(length, '\0');
  if (length > 0 &&
      streamer.readRaw(&text[0], length) != static_cast<TSize>(length)) {
    return kResultFalse;
  }
  ShellState restored;
  std::string error;
  if (!decodeState(text, &restored, &error)) {
    logError("The state does not read: " + error);
    return kResultFalse;
  }
  // The preset first, its values after: the state's values are newer. A
  // preset the bundle no longer has keeps the one that plays.
  const int32_t index = settings_.presetIndex(restored.preset);
  if (index >= 0) {
    if (!engine_->applyPreset(settings_.presets[static_cast<size_t>(index)],
                              &error)) {
      logError(error);
    }
    preset_.store(index);
    const size_t count = settings_.presets.size();
    EditControllerEx1::setParamNormalized(
        presetParamId(),
        count > 1 ? static_cast<double>(index) / static_cast<double>(count - 1)
                  : 0);
    notifyPreset(static_cast<uint32_t>(index));
  }
  for (const auto& [id, plain] : restored.params) {
    const ParamMapping* m = mapping(id);
    if (m == nullptr) continue;
    engine_->setParam(id, plain);
    EditControllerEx1::setParamNormalized(id, m->toNormalized(plain));
    for (PluginObserver* observer : observers_) {
      observer->paramChanged(id, m->toNormalized(plain));
    }
  }
  for (const auto& [id, value] : restored.controls) {
    for (uint32_t i = 0; i < settings_.controls.size(); ++i) {
      if (settings_.controls[i].id != id) continue;
      const float clamped =
          static_cast<float>(std::min(1.0, std::max(0.0, value)));
      controlValues_[i].store(clamped);
      controlChanges_.push({i, clamped});
      EditControllerEx1::setParamNormalized(settings_.controls[i].paramId,
                                            clamped);
    }
  }
  return kResultOk;
}

tresult PLUGIN_API Plugin::getState(IBStream* state) {
  if (state == nullptr || engine_ == nullptr) return kInvalidArgument;
  ShellState saved;
  const int32_t index = preset_.load();
  if (index >= 0 && static_cast<size_t>(index) < settings_.presets.size()) {
    saved.preset = settings_.presets[static_cast<size_t>(index)].id;
  }
  for (const ParamMapping& m : mappings_) {
    saved.params.emplace_back(m.id, engine_->value(m.id));
  }
  for (size_t i = 0; i < settings_.controls.size(); ++i) {
    const float value = controlValues_[i].load();
    if (std::isfinite(value)) saved.controls.emplace_back(settings_.controls[i].id, value);
  }
  const std::string text = encodeState(saved);
  if (text.size() > kMaxStateLength) return kResultFalse;
  IBStreamer streamer(state, kLittleEndian);
  const uint32 length = static_cast<uint32>(text.size());
  if (!streamer.writeInt32u(kStateMagic) ||
      !streamer.writeInt32u(kStateVersion) || !streamer.writeInt32u(length) ||
      streamer.writeRaw(text.data(), length) != static_cast<TSize>(length)) {
    return kResultFalse;
  }
  return kResultOk;
}

tresult PLUGIN_API Plugin::setBusArrangements(SpeakerArrangement* inputs,
                                              int32 numIns,
                                              SpeakerArrangement* outputs,
                                              int32 numOuts) {
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
  sampleRate_ = setup.sampleRate;
  clock_.reset(setup.sampleRate);
  const uint32_t latency = static_cast<uint32_t>(engine_->latency());
  tail_ = engine_->tail();
  const bool changed = latency != latency_;
  latency_ = latency;
  if (changed) {
    if (IComponentHandler* handler = getComponentHandler()) {
      handler->restartComponent(kLatencyChanged);
    }
  }
  return SingleComponentEffect::setupProcessing(setup);
}

tresult PLUGIN_API Plugin::setProcessing(TBool) { return kResultOk; }

// .............................................................................
const ParamMapping* Plugin::mapping(uint32_t id) const {
  const auto it = std::lower_bound(
      mappings_.begin(), mappings_.end(), id,
      [](const ParamMapping& m, uint32_t value) { return m.id < value; });
  return it != mappings_.end() && it->id == id ? &*it : nullptr;
}

int32_t Plugin::controlIndex(uint32_t id) const {
  for (size_t i = 0; i < controlIds_.size(); ++i) {
    if (controlIds_[i] == id) return static_cast<int32_t>(i);
  }
  return -1;
}

tresult PLUGIN_API Plugin::process(ProcessData& data) {
  processing_.fetch_add(1, std::memory_order_seq_cst);
  Engine* engine = rtEngine_.load(std::memory_order_seq_cst);
  if (engine != nullptr) {
    const uint32_t frames =
        data.numSamples > 0 ? static_cast<uint32_t>(data.numSamples) : 0;
    // A call that renders nothing - a host flushing its parameters - keeps
    // the events it took from the queues for the next block that renders.
    // The controls a restored state set.
    ControlChange change{};
    while (controlChanges_.pop(change)) {
      const ShellControl& control = settings_.controls[change.index];
      addEvent(controlChangeEvent(control.channel, control.cc,
                                  sevenBits(change.value), 0));
    }
    takeEditorMidi(data);
    takeParams(data, *engine, frames);
    takeEvents(data, frames);
    if (frames > 0 && data.numOutputs >= 1 &&
        data.outputs[0].numChannels > 0) {
      takeTransport(data, frames);
      // Offline the block waits for its changes and for the instrument of
      // its preset; the realtime path never waits.
      if (data.processMode == kOffline) {
        engine->waitForParams();
        engine->waitForPreset(kOfflineLoadMs);
      }
      EngineBlock block;
      block.outputs = data.outputs[0].channelBuffers32;
      block.channels = static_cast<uint32_t>(data.outputs[0].numChannels);
      block.frames = frames;
      block.offline = data.processMode == kOffline;
      block.events = events_.data();
      block.numEvents = numEvents_;
      block.transport = &snapshot_;
      engine->render(block);
      numEvents_ = 0;
      data.outputs[0].silenceFlags = 0;
    }
  }
  processing_.fetch_sub(1, std::memory_order_release);
  return engine != nullptr ? kResultOk : kResultFalse;
}

// The messages the editor played: to the graph at the block's start, and
// to the DAW through the event output.
void Plugin::takeEditorMidi(ProcessData& data) AUD_VST3_NONBLOCKING {
  EditorMidi m{};
  while (editorMidi_.pop(m)) {
    addEvent(midiEvent(m.status, m.data1, m.data2, 0));
    IEventList* out = data.outputEvents;
    if (out == nullptr) continue;
    const int16 channel = static_cast<int16>(m.status & 0x0F);
    Event e{};
    e.busIndex = 0;
    e.sampleOffset = 0;
    switch (m.status & 0xF0) {
      case 0x90:
        if (m.data2 > 0) {
          e.type = Event::kNoteOnEvent;
          e.noteOn.channel = channel;
          e.noteOn.pitch = m.data1;
          e.noteOn.velocity = m.data2 / 127.0f;
          e.noteOn.noteId = -1;
          break;
        }
        [[fallthrough]];
      case 0x80:
        e.type = Event::kNoteOffEvent;
        e.noteOff.channel = channel;
        e.noteOff.pitch = m.data1;
        e.noteOff.velocity = (m.status & 0xF0) == 0x80 ? m.data2 / 127.0f : 0;
        e.noteOff.noteId = -1;
        break;
      case 0xA0:
        e.type = Event::kPolyPressureEvent;
        e.polyPressure.channel = channel;
        e.polyPressure.pitch = m.data1;
        e.polyPressure.pressure = m.data2 / 127.0f;
        e.polyPressure.noteId = -1;
        break;
      case 0xB0:
      case 0xD0:
      case 0xE0:
        e.type = Event::kLegacyMIDICCOutEvent;
        e.midiCCOut.channel = static_cast<int8>(channel);
        e.midiCCOut.controlNumber =
            (m.status & 0xF0) == 0xB0   ? m.data1
            : (m.status & 0xF0) == 0xD0 ? static_cast<uint8>(kAfterTouch)
                                        : static_cast<uint8>(kPitchBend);
        e.midiCCOut.value = static_cast<int8>(
            (m.status & 0xF0) == 0xB0 ? m.data2 : m.data1);
        e.midiCCOut.value2 =
            static_cast<int8>((m.status & 0xF0) == 0xE0 ? m.data2 : 0);
        break;
      default:
        continue;
    }
    out->addEvent(e);
  }
}

void Plugin::addEvent(const AudEvent& event) AUD_VST3_NONBLOCKING {
  if (numEvents_ < kMaxEvents) {
    events_[numEvents_++] = event;
  } else {
    ++droppedEvents_;
  }
}

void Plugin::takeParams(ProcessData& data, Engine& engine,
                        uint32_t frames) AUD_VST3_NONBLOCKING {
  IParameterChanges* changes = data.inputParameterChanges;
  if (changes == nullptr) return;
  const uint32_t last = frames > 0 ? frames - 1 : 0;
  const int32 count = changes->getParameterCount();
  for (int32 i = 0; i < count; ++i) {
    IParamValueQueue* queue = changes->getParameterData(i);
    if (queue == nullptr) continue;
    const uint32_t id = queue->getParameterId();
    const int32 points = queue->getPointCount();
    if (points <= 0) continue;
    uint32_t channel = 0;
    uint32_t controller = 0;
    if (midiParamOf(id, &channel, &controller)) {
      // Every point: a control change is an event, not a value.
      for (int32 p = 0; p < points; ++p) {
        int32 offset = 0;
        ParamValue value = 0;
        if (queue->getPoint(p, offset, value) != kResultTrue) continue;
        addEvent(midiParamEvent(
            channel, controller, value,
            std::min(static_cast<uint32_t>(std::max(0, offset)), last)));
      }
      continue;
    }
    const int32_t control = controlIndex(id);
    if (control >= 0) {
      const ShellControl& c = settings_.controls[static_cast<size_t>(control)];
      for (int32 p = 0; p < points; ++p) {
        int32 offset = 0;
        ParamValue value = 0;
        if (queue->getPoint(p, offset, value) != kResultTrue) continue;
        addEvent(controlChangeEvent(
            c.channel, c.cc, sevenBits(value),
            std::min(static_cast<uint32_t>(std::max(0, offset)), last)));
        controlValues_[static_cast<size_t>(control)].store(
            static_cast<float>(value), std::memory_order_relaxed);
      }
      continue;
    }
    // A preset or a graph parameter: its last value in the block.
    int32 offset = 0;
    ParamValue value = 0;
    if (queue->getPoint(points - 1, offset, value) != kResultTrue) continue;
    if (id == presetParamId()) {
      const int32_t index = presetOf(value);
      if (index >= 0 && index != preset_.load(std::memory_order_relaxed)) {
        preset_.store(index, std::memory_order_relaxed);
        engine.requestPreset(static_cast<uint32_t>(index));
      }
      continue;
    }
    if (const ParamMapping* m = mapping(id)) engine.pushParam(m->id, m->toPlain(value));
  }
}

void Plugin::takeEvents(ProcessData& data, uint32_t frames) AUD_VST3_NONBLOCKING {
  IEventList* events = data.inputEvents;
  if (events == nullptr) return;
  const uint32_t last = frames > 0 ? frames - 1 : 0;
  const int32 count = events->getEventCount();
  for (int32 i = 0; i < count; ++i) {
    Event e{};
    if (events->getEvent(i, e) != kResultOk) continue;
    const uint32_t offset =
        std::min(static_cast<uint32_t>(std::max(0, e.sampleOffset)), last);
    switch (e.type) {
      case Event::kNoteOnEvent: {
        const uint32_t channel = static_cast<uint32_t>(e.noteOn.channel) & 0xF;
        const uint32_t pitch = static_cast<uint32_t>(e.noteOn.pitch);
        // A note on without velocity is a note off, as in MIDI.
        addEvent(e.noteOn.velocity > 0
                     ? noteOnEvent(channel, pitch, e.noteOn.velocity, offset)
                     : noteOffEvent(channel, pitch, 0, offset));
        break;
      }
      case Event::kNoteOffEvent:
        addEvent(noteOffEvent(static_cast<uint32_t>(e.noteOff.channel) & 0xF,
                              static_cast<uint32_t>(e.noteOff.pitch),
                              e.noteOff.velocity, offset));
        break;
      case Event::kPolyPressureEvent:
        addEvent(polyPressureEvent(
            static_cast<uint32_t>(e.polyPressure.channel) & 0xF,
            static_cast<uint32_t>(e.polyPressure.pitch),
            e.polyPressure.pressure, offset));
        break;
      default:
        break;
    }
  }
}

void Plugin::takeTransport(ProcessData& data, uint32_t frames) AUD_VST3_NONBLOCKING {
  HostTransport host;
  if (const ProcessContext* context = data.processContext) {
    const uint32 state = context->state;
    host.tempoValid = (state & ProcessContext::kTempoValid) != 0;
    host.tempo = context->tempo;
    host.playing = (state & ProcessContext::kPlaying) != 0;
    host.positionValid = (state & ProcessContext::kProjectTimeMusicValid) != 0;
    host.position = context->projectTimeMusic;
    host.barValid = (state & ProcessContext::kBarPositionValid) != 0;
    host.barStart = context->barPositionMusic;
    host.signatureValid = (state & ProcessContext::kTimeSigValid) != 0;
    host.numerator = static_cast<uint32_t>(std::max(1, context->timeSigNumerator));
    host.denominator =
        static_cast<uint32_t>(std::max(1, context->timeSigDenominator));
    host.looping = (state & ProcessContext::kCycleActive) != 0 &&
                   (state & ProcessContext::kCycleValid) != 0;
    host.loopStart = context->cycleStartMusic;
    host.loopEnd = context->cycleEndMusic;
  }
  clock_.advance(host, frames, &segment_);
  snapshot_ = AudTransportSnapshot{};
  snapshot_.struct_size = sizeof(AudTransportSnapshot);
  snapshot_.capabilities = AUD_TRANSPORT_CAP_TEMPO | AUD_TRANSPORT_CAP_SEEK |
                           AUD_TRANSPORT_CAP_START_STOP |
                           AUD_TRANSPORT_CAP_TIME_SIGNATURE |
                           AUD_TRANSPORT_CAP_LOOP;
  snapshot_.num_segments = 1;
  snapshot_.segments = &segment_;
}

uint32 PLUGIN_API Plugin::getLatencySamples() { return latency_; }

uint32 PLUGIN_API Plugin::getTailSamples() { return tail_ > 0 ? tail_ : kNoTail; }

IPlugView* PLUGIN_API Plugin::createView(FIDString name) {
  // Without an editor app the DAW shows its generic view.
  if (name == nullptr || std::strcmp(name, ViewType::kEditor) != 0 ||
      settings_.editor.empty() || engine_ == nullptr) {
    return nullptr;
  }
  return createEditorView(this);
}

tresult PLUGIN_API Plugin::setParamNormalized(ParamID tag, ParamValue value) {
  const tresult result = EditControllerEx1::setParamNormalized(tag, value);
  if (tag == presetParamId()) {
    const int32_t index = presetOf(value);
    if (index >= 0) notifyPreset(static_cast<uint32_t>(index));
    return result;
  }
  if (mapping(tag) != nullptr || controlIndex(tag) >= 0) {
    for (PluginObserver* observer : observers_) observer->paramChanged(tag, value);
  }
  return result;
}

// .............................................................................
void Plugin::notifyPreset(uint32_t index) {
  for (PluginObserver* observer : observers_) observer->presetChanged(index);
}

// .............................................................................
void Plugin::addObserver(PluginObserver* observer) {
  observers_.push_back(observer);
}

// .............................................................................
void Plugin::removeObserver(PluginObserver* observer) {
  observers_.erase(std::remove(observers_.begin(), observers_.end(), observer),
                   observers_.end());
}

// .............................................................................
void Plugin::editBegin(uint32_t id, const PluginObserver* owner) {
  if (openEdits_[owner].insert(id).second) beginEdit(id);
}

// .............................................................................
void Plugin::edit(uint32_t id, double normalized, PluginObserver* origin) {
  EditControllerEx1::setParamNormalized(id, normalized);
  performEdit(id, normalized);
  for (PluginObserver* observer : observers_) {
    if (observer != origin) observer->paramChanged(id, normalized);
  }
}

// .............................................................................
void Plugin::editEnd(uint32_t id, const PluginObserver* owner) {
  const auto it = openEdits_.find(owner);
  if (it == openEdits_.end() || it->second.erase(id) == 0) return;
  if (it->second.empty()) openEdits_.erase(it);
  endEdit(id);
}

// .............................................................................
void Plugin::endEdits(const PluginObserver* owner) {
  const auto it = openEdits_.find(owner);
  if (it == openEdits_.end()) return;
  const std::set<uint32_t> ids = it->second;
  openEdits_.erase(it);
  for (const uint32_t id : ids) endEdit(id);
}

// .............................................................................
void Plugin::selectPreset(uint32_t index, PluginObserver* origin) {
  const size_t count = settings_.presets.size();
  if (engine_ == nullptr || index >= count) return;
  const double normalized =
      count > 1 ? static_cast<double>(index) / static_cast<double>(count - 1) : 0;
  preset_.store(static_cast<int32_t>(index));
  engine_->requestPreset(index);
  // The DAW records the choice like a program change of its own.
  EditControllerEx1::setParamNormalized(presetParamId(), normalized);
  beginEdit(presetParamId());
  performEdit(presetParamId(), normalized);
  endEdit(presetParamId());
  for (PluginObserver* observer : observers_) {
    if (observer != origin) observer->presetChanged(index);
  }
}

// .............................................................................
bool Plugin::editorMidi(const std::vector<uint8_t>& bytes) {
  bool all = true;
  size_t i = 0;
  while (i < bytes.size()) {
    const uint8_t status = bytes[i];
    const uint32_t count = midiDataBytes(status);
    // A data byte without its status, or a system message: skipped.
    if (count == 0) {
      ++i;
      continue;
    }
    // A message cut off at the end.
    if (i + count >= bytes.size()) break;
    const uint8_t data1 = bytes[i + 1] & 0x7F;
    const uint8_t data2 = count == 2 ? bytes[i + 2] & 0x7F : 0;
    if (editorMidi_.push({status, data1, data2})) {
      followEditorNote(status, data1, data2);
    } else {
      all = false;
    }
    i += 1 + count;
  }
  return all;
}

// Keeps editorNotes_ in step with a message the editor played.
void Plugin::followEditorNote(uint8_t status, uint8_t data1, uint8_t data2) {
  const size_t channel = status & 0x0F;
  switch (status & 0xF0) {
    case 0x90:
      editorNotes_.set(channel * 128 + data1, data2 > 0);
      break;
    case 0x80:
      editorNotes_.reset(channel * 128 + data1);
      break;
    case 0xB0:
      // All sound off, all notes off.
      if (data1 == 120 || data1 == 123) {
        for (size_t key = 0; key < 128; ++key) editorNotes_.reset(channel * 128 + key);
      }
      break;
    default:
      break;
  }
}

size_t Plugin::releaseEditorNotes() {
  size_t released = 0;
  for (size_t note = 0; note < editorNotes_.size(); ++note) {
    if (!editorNotes_.test(note)) continue;
    const uint8_t status = static_cast<uint8_t>(0x80 | (note / 128));
    const uint8_t key = static_cast<uint8_t>(note % 128);
    // A full queue keeps the note: the next release tries again.
    if (!editorMidi_.push({status, key, 0})) break;
    editorNotes_.reset(note);
    released += 1;
  }
  return released;
}

tresult PLUGIN_API Plugin::getMidiControllerAssignment(int32 busIndex,
                                                       int16 channel,
                                                       CtrlNumber controller,
                                                       ParamID& id) {
  if (busIndex != 0 || channel < 0 ||
      channel >= static_cast<int16>(kMidiChannels) || controller < 0 ||
      controller >= static_cast<CtrlNumber>(kMidiControllers)) {
    return kResultFalse;
  }
  const uint32_t index = static_cast<uint32_t>(channel) * kMidiControllers +
                         static_cast<uint32_t>(controller);
  if (index >= midiParams_.size() || !midiParams_[index]) return kResultFalse;
  id = midiParamId(static_cast<uint32_t>(channel),
                   static_cast<uint32_t>(controller));
  return kResultTrue;
}

}  // namespace aud_vst3
