// @license
// Copyright (c) Audanika. All Rights Reserved.
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

// The test host of the shell (ticket 37): loads a plugin bundle as a DAW
// does, through the hosting classes of the VST3 SDK, and checks what a DAW
// relies on - without a DAW, so that it runs in scripts and on CI:
//
// - every preset sounds: chosen through the parameter "Preset", a note on
//   each of the MIDI channels 1 to 4 renders offline above -60 dBFS, and
//   the note offs let it fade
// - the program list has a program per preset, IMidiMapping assigns the
//   control changes, channel pressure and pitch bend of channel 1
// - a state saved by one instance reads back the same from a second one
// - rendered in realtime mode at 128 frames, the longest block stays
//   within the block's time
//
// Every preset's sound can go to WAV files (--wav <dir>), 32-bit float, to
// listen to or to compare with the app. One JSON line per check goes to
// stdout; the exit code is 1 when a check fails.
//
//   aud_vst3_host <bundle.vst3> [--wav <dir>] [--presets n]
//     [--realtime-seconds s]

#include <mach/mach_time.h>

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

#include "pluginterfaces/base/ibstream.h"
#include "pluginterfaces/vst/ivstaudioprocessor.h"
#include "pluginterfaces/vst/ivstcomponent.h"
#include "pluginterfaces/vst/ivsteditcontroller.h"
#include "pluginterfaces/vst/ivstevents.h"
#include "pluginterfaces/vst/ivstmidicontrollers.h"
#include "pluginterfaces/vst/ivstprocesscontext.h"
#include "pluginterfaces/vst/ivstunits.h"
#include "public.sdk/source/common/memorystream.h"
#include "public.sdk/source/vst/hosting/eventlist.h"
#include "public.sdk/source/vst/hosting/hostclasses.h"
#include "public.sdk/source/vst/hosting/module.h"
#include "public.sdk/source/vst/hosting/parameterchanges.h"

using namespace Steinberg;
using namespace Steinberg::Vst;

namespace {

constexpr double kSampleRate = 48000;
constexpr int32 kBlock = 512;
constexpr int32 kRealtimeBlock = 128;
// A preset sounds when its notes peak above this.
constexpr double kAudiblePeak = 0.001;  // -60 dBFS

int failures = 0;

void report(const std::string& check, bool ok, const std::string& detail) {
  std::printf("{\"check\":\"%s\",\"ok\":%s%s%s}\n", check.c_str(),
              ok ? "true" : "false", detail.empty() ? "" : ",", detail.c_str());
  std::fflush(stdout);
  if (!ok) failures += 1;
}

double nowSeconds() {
  static mach_timebase_info_data_t timebase = [] {
    mach_timebase_info_data_t info;
    mach_timebase_info(&info);
    return info;
  }();
  return static_cast<double>(mach_absolute_time()) * timebase.numer /
         timebase.denom / 1e9;
}

std::string text(const String128 value) {
  std::string out;
  for (int i = 0; i < 128 && value[i] != 0; ++i) {
    out += value[i] < 128 ? static_cast<char>(value[i]) : '?';
  }
  return out;
}

// Writes interleaved stereo float frames as a WAV file.
void writeWav(const std::string& path, const std::vector<float>& left,
              const std::vector<float>& right) {
  FILE* file = std::fopen(path.c_str(), "wb");
  if (file == nullptr) return;
  const uint32_t frames = static_cast<uint32_t>(left.size());
  const uint32_t dataBytes = frames * 2 * 4;
  auto u32 = [&](uint32_t v) { std::fwrite(&v, 4, 1, file); };
  auto u16 = [&](uint16_t v) { std::fwrite(&v, 2, 1, file); };
  std::fwrite("RIFF", 1, 4, file);
  u32(36 + dataBytes);
  std::fwrite("WAVEfmt ", 1, 8, file);
  u32(16);
  u16(3);  // IEEE float
  u16(2);
  u32(static_cast<uint32_t>(kSampleRate));
  u32(static_cast<uint32_t>(kSampleRate) * 8);
  u16(8);
  u16(32);
  std::fwrite("data", 1, 4, file);
  u32(dataBytes);
  for (uint32_t i = 0; i < frames; ++i) {
    std::fwrite(&left[i], 4, 1, file);
    std::fwrite(&right[i], 4, 1, file);
  }
  std::fclose(file);
}

// One plugin instance and the buffers of its process calls.
class Instance {
 public:
  Instance(VST3::Hosting::PluginFactory& factory, const VST3::UID& cid,
           FUnknown* host) {
    component_ = factory.createInstance<IComponent>(cid);
    if (!component_ || component_->initialize(host) != kResultOk) {
      component_ = nullptr;
      return;
    }
    processor_ = FUnknownPtr<IAudioProcessor>(component_);
    controller_ = FUnknownPtr<IEditController>(component_);
    midi_ = FUnknownPtr<IMidiMapping>(component_);
    units_ = FUnknownPtr<IUnitInfo>(component_);
  }

  ~Instance() {
    if (!component_) return;
    if (active_) stop();
    component_->terminate();
  }

  bool valid() const { return component_ && processor_ && controller_; }
  IComponent* component() { return component_; }
  IEditController* controller() { return controller_; }
  IMidiMapping* midi() { return midi_; }
  IUnitInfo* units() { return units_; }

  bool start(int32 mode, int32 block) {
    block_ = block;
    ProcessSetup setup{mode, kSample32, block, kSampleRate};
    if (processor_->setupProcessing(setup) != kResultOk) return false;
    component_->activateBus(kAudio, kOutput, 0, true);
    component_->activateBus(kEvent, kInput, 0, true);
    if (component_->setActive(true) != kResultOk) return false;
    processor_->setProcessing(true);
    left_.assign(block, 0);
    right_.assign(block, 0);
    mode_ = mode;
    active_ = true;
    return true;
  }

  void stop() {
    processor_->setProcessing(false);
    component_->setActive(false);
    active_ = false;
  }

  // The parameter changes and events of the next block.
  ParameterChanges& changes() { return changes_; }
  EventList& events() { return events_; }

  // Renders one block; appends it to `left` and `right` when given.
  // Returns the time process() took in seconds.
  double process(std::vector<float>* left = nullptr,
                 std::vector<float>* right = nullptr) {
    float* channels[2] = {left_.data(), right_.data()};
    AudioBusBuffers output{};
    output.numChannels = 2;
    output.channelBuffers32 = channels;
    ProcessContext context{};
    context.state = ProcessContext::kTempoValid | ProcessContext::kTimeSigValid;
    context.tempo = 120;
    context.timeSigNumerator = 4;
    context.timeSigDenominator = 4;
    context.sampleRate = kSampleRate;
    context.projectTimeSamples = position_;
    ProcessData data{};
    data.processMode = mode_;
    data.symbolicSampleSize = kSample32;
    data.numSamples = block_;
    data.numInputs = 0;
    data.numOutputs = 1;
    data.outputs = &output;
    data.inputParameterChanges = &changes_;
    data.inputEvents = &events_;
    data.processContext = &context;
    const double start = nowSeconds();
    processor_->process(data);
    const double elapsed = nowSeconds() - start;
    position_ += block_;
    if (left != nullptr) left->insert(left->end(), left_.begin(), left_.end());
    if (right != nullptr) right->insert(right->end(), right_.begin(), right_.end());
    changes_.clearQueue();
    events_.clear();
    return elapsed;
  }

  // Sets parameter `id` to `normalized` at the start of the next block.
  void setParam(ParamID id, ParamValue normalized) {
    int32 index = 0;
    if (IParamValueQueue* queue = changes_.addParameterData(id, index)) {
      int32 point = 0;
      queue->addPoint(0, normalized, point);
    }
    controller_->setParamNormalized(id, normalized);
  }

  void note(bool on, int16 channel, int16 pitch, int32 offset) {
    Event e{};
    e.busIndex = 0;
    e.sampleOffset = offset;
    if (on) {
      e.type = Event::kNoteOnEvent;
      e.noteOn.channel = channel;
      e.noteOn.pitch = pitch;
      e.noteOn.velocity = 0.8f;
      e.noteOn.noteId = -1;
    } else {
      e.type = Event::kNoteOffEvent;
      e.noteOff.channel = channel;
      e.noteOff.pitch = pitch;
      e.noteOff.velocity = 0;
      e.noteOff.noteId = -1;
    }
    events_.addEvent(e);
  }

 private:
  IPtr<IComponent> component_;
  FUnknownPtr<IAudioProcessor> processor_;
  FUnknownPtr<IEditController> controller_;
  FUnknownPtr<IMidiMapping> midi_;
  FUnknownPtr<IUnitInfo> units_;
  ParameterChanges changes_{64};
  EventList events_{256};
  std::vector<float> left_;
  std::vector<float> right_;
  int32 block_ = kBlock;
  int32 mode_ = kOffline;
  int64 position_ = 0;
  bool active_ = false;
};

// The parameter "Preset": the one with the program change flag.
bool presetParam(IEditController* controller, ParameterInfo* out) {
  for (int32 i = 0; i < controller->getParameterCount(); ++i) {
    ParameterInfo info{};
    if (controller->getParameterInfo(i, info) == kResultOk &&
        (info.flags & ParameterInfo::kIsProgramChange) != 0) {
      *out = info;
      return true;
    }
  }
  return false;
}

double peakOf(const std::vector<float>& left, const std::vector<float>& right,
              size_t from, size_t to) {
  double peak = 0;
  for (size_t i = from; i < std::min(to, left.size()); ++i) {
    peak = std::max(peak, static_cast<double>(std::fabs(left[i])));
    peak = std::max(peak, static_cast<double>(std::fabs(right[i])));
  }
  return peak;
}

bool finite(const std::vector<float>& samples) {
  return std::all_of(samples.begin(), samples.end(),
                     [](float s) { return std::isfinite(s); });
}

}  // namespace

int main(int argc, char** argv) {
  if (argc < 2) {
    std::fprintf(stderr, "usage: aud_vst3_host <bundle.vst3> [--wav <dir>] "
                         "[--presets n] [--realtime-seconds s]\n");
    return 2;
  }
  const std::string bundle = argv[1];
  std::string wavDir;
  int32 maxPresets = 1 << 30;
  double realtimeSeconds = 5;
  for (int i = 2; i < argc; ++i) {
    const std::string arg = argv[i];
    if (arg == "--wav" && i + 1 < argc) wavDir = argv[++i];
    else if (arg == "--presets" && i + 1 < argc) maxPresets = std::atoi(argv[++i]);
    else if (arg == "--realtime-seconds" && i + 1 < argc) realtimeSeconds = std::atof(argv[++i]);
  }

  std::string error;
  auto module = VST3::Hosting::Module::create(bundle, error);
  if (!module) {
    report("load", false, "\"error\":\"" + error + "\"");
    return 1;
  }
  auto factory = module->getFactory();
  VST3::UID cid;
  bool found = false;
  std::string className;
  for (const auto& info : factory.classInfos()) {
    if (info.category() == kVstAudioEffectClass) {
      cid = info.ID();
      className = info.name();
      found = true;
      break;
    }
  }
  if (!found) {
    report("load", false, "\"error\":\"no audio effect class\"");
    return 1;
  }
  IPtr<HostApplication> hostApplication = owned(new HostApplication());
  FUnknown* host = static_cast<IHostApplication*>(hostApplication.get());
  const double loadStart = nowSeconds();
  Instance a(factory, cid, host);
  report("load", a.valid(),
         "\"class\":\"" + className + "\",\"ms\":" +
             std::to_string((nowSeconds() - loadStart) * 1000));
  if (!a.valid()) return 1;

  // The program list and the parameter "Preset".
  ParameterInfo preset{};
  const bool hasPreset = presetParam(a.controller(), &preset);
  int32 presets = hasPreset ? preset.stepCount + 1 : 0;
  int32 programs = -1;
  if (a.units() != nullptr && a.units()->getProgramListCount() > 0) {
    ProgramListInfo list{};
    if (a.units()->getProgramListInfo(0, list) == kResultOk) programs = list.programCount;
  }
  report("presets", hasPreset && programs == presets,
         "\"presets\":" + std::to_string(presets) + ",\"programs\":" +
             std::to_string(programs));

  // IMidiMapping: CC 74, channel pressure and pitch bend of channel 1.
  if (a.midi() != nullptr) {
    ParamID cc = 0, pressure = 0, bend = 0, none = 0;
    const bool mapped =
        a.midi()->getMidiControllerAssignment(0, 0, 74, cc) == kResultTrue &&
        a.midi()->getMidiControllerAssignment(0, 0, kAfterTouch, pressure) == kResultTrue &&
        a.midi()->getMidiControllerAssignment(0, 0, kPitchBend, bend) == kResultTrue &&
        a.midi()->getMidiControllerAssignment(0, 16, 74, none) != kResultTrue &&
        a.midi()->getMidiControllerAssignment(1, 0, 74, none) != kResultTrue;
    report("midiMapping", mapped, "");
  } else {
    report("midiMapping", false, "\"error\":\"no IMidiMapping\"");
  }

  // Every preset sounds, offline.
  if (!a.start(kOffline, kBlock)) {
    report("setup", false, "");
    return 1;
  }
  const int32 blocks = static_cast<int32>(kSampleRate / kBlock);
  for (int32 p = 0; p < std::min(presets, maxPresets); ++p) {
    std::vector<float> left, right;
    const double start = nowSeconds();
    a.setParam(preset.id, presets > 1 ? static_cast<double>(p) / (presets - 1) : 0);
    String128 name{};
    if (a.controller() != nullptr) {
      a.controller()->getParamStringByValue(
          preset.id, presets > 1 ? static_cast<double>(p) / (presets - 1) : 0, name);
    }
    // A quarter second of silence while the preset loads, the notes for two
    // seconds, then a second of their release.
    for (int32 b = 0; b < blocks / 4; ++b) a.process(&left, &right);
    const size_t noteStart = left.size();
    const int16 pitches[4] = {48, 60, 72, 76};
    for (int16 channel = 0; channel < 4; ++channel) {
      a.note(true, channel, pitches[channel], 0);
    }
    for (int32 b = 0; b < blocks * 2; ++b) a.process(&left, &right);
    const size_t noteEnd = left.size();
    for (int16 channel = 0; channel < 4; ++channel) {
      a.note(false, channel, pitches[channel], 0);
    }
    for (int32 b = 0; b < blocks; ++b) a.process(&left, &right);
    const double peak = peakOf(left, right, noteStart, noteEnd);
    const double tail = peakOf(left, right, left.size() - kBlock, left.size());
    const bool ok = finite(left) && finite(right) && peak > kAudiblePeak;
    report("preset", ok,
           "\"index\":" + std::to_string(p) + ",\"name\":\"" + text(name) +
               "\",\"peak\":" + std::to_string(peak) + ",\"tailPeak\":" +
               std::to_string(tail) + ",\"ms\":" +
               std::to_string((nowSeconds() - start) * 1000));
    if (!wavDir.empty()) {
      writeWav(wavDir + "/" + std::to_string(p) + ".wav", left, right);
    }
  }
  a.stop();

  // The state reads back the same from a second instance.
  if (presets > 1) a.setParam(preset.id, 1.0);
  a.start(kOffline, kBlock);
  a.process();
  a.stop();
  MemoryStream saved;
  const bool got = a.component()->getState(&saved) == kResultOk;
  Instance b(factory, cid, host);
  saved.seek(0, IBStream::kIBSeekSet, nullptr);
  const bool set = b.valid() && b.component()->setState(&saved) == kResultOk;
  MemoryStream again;
  const bool gotAgain = set && b.component()->getState(&again) == kResultOk;
  const bool same =
      gotAgain && saved.getSize() == again.getSize() &&
      std::memcmp(saved.getData(), again.getData(),
                  static_cast<size_t>(saved.getSize())) == 0;
  report("state", got && set && same,
         "\"bytes\":" + std::to_string(saved.getSize()));

  // Realtime at 128 frames: the longest block within the block's time.
  if (realtimeSeconds > 0 && b.valid() && b.start(kRealtime, kRealtimeBlock)) {
    const double budget = kRealtimeBlock / kSampleRate;
    double longest = 0;
    double sum = 0;
    const int32 count = static_cast<int32>(realtimeSeconds * kSampleRate / kRealtimeBlock);
    for (int32 i = 0; i < count; ++i) {
      if (i % 375 == 0) {
        for (int16 channel = 0; channel < 4; ++channel) b.note(true, channel, 60 + channel, 0);
      }
      if (i % 375 == 300) {
        for (int16 channel = 0; channel < 4; ++channel) b.note(false, channel, 60 + channel, 0);
      }
      const double elapsed = b.process();
      longest = std::max(longest, elapsed);
      sum += elapsed;
    }
    report("realtime", longest < budget,
           "\"blocks\":" + std::to_string(count) + ",\"meanMs\":" +
               std::to_string(sum / count * 1000) + ",\"maxMs\":" +
               std::to_string(longest * 1000) + ",\"budgetMs\":" +
               std::to_string(budget * 1000));
    b.stop();
  }
  return failures == 0 ? 0 : 1;
}
