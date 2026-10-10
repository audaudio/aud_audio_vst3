// @license
// Copyright (c) Audanika. All Rights Reserved.
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

// The test host of the spike S0-plugin-ui (ticket 24): a minimal VST3 host
// that behaves like a DAW where the measurements need it and runs the
// scenarios of the plan reproducibly. REAPER and Live run the same plugins
// for the numbers of record; this host runs them where a DAW cannot be
// scripted or instrumented - RealtimeSanitizer needs its runtime at process
// start, which a notarized DAW refuses.
//
// - Audio: the default output device at 48 kHz in blocks of 128 frames
//   (CoreAudio's I/O thread calls process), or a timer thread (--no-audio).
//   The device plays silence unless --audible; the plugins render anyway.
// - Parameters: performEdit of a plugin reaches its next process call, as
//   in a DAW; automation from the host goes to the controller on the UI
//   thread and to the processor.
// - Measurements: phys_footprint of this process and of its children (the
//   editor processes), the longest stall of the UI thread, device overloads.
//   Every record goes to ~/Library/Logs/aud_audio_vst3/host-<pid>.jsonl.
//
//   aud_spike_host --plugin <bundle> [--plugin <bundle>] [--instances n]
//     [--scenario open|closed|test|automate|cycles|crash|soak|pair]
//     [--duration s] [--cycles n] [--no-audio] [--audible]
//   aud_spike_host --measure <pid>     footprint and CPU of a DAW
//   aud_spike_host --session           display asleep, screen locked

#import <AudioToolbox/AudioToolbox.h>
#import <Cocoa/Cocoa.h>
#import <CoreAudio/CoreAudio.h>
#include <libproc.h>
#include <mach/mach_time.h>
#include <signal.h>
#include <sys/resource.h>
#include <sys/stat.h>
#include <unistd.h>

#include <atomic>
#include <cmath>
#include <cstdio>
#include <memory>
#include <string>
#include <thread>
#include <vector>

#include "pluginterfaces/gui/iplugview.h"
#include "pluginterfaces/vst/ivstaudioprocessor.h"
#include "pluginterfaces/vst/ivsteditcontroller.h"
#include "public.sdk/source/vst/hosting/hostclasses.h"
#include "public.sdk/source/vst/hosting/module.h"
#include "public.sdk/source/vst/hosting/parameterchanges.h"
#include "public.sdk/source/vst/hosting/plugprovider.h"
#include "public.sdk/source/vst/hosting/processdata.h"

using namespace Steinberg;
using namespace Steinberg::Vst;

namespace {

constexpr double kSampleRate = 48000;
constexpr UInt32 kBlockFrames = 128;
constexpr int32 kMaxBlock = 4096;

// ............................................................................
// Clock and log

int64_t nowNs() {
  static mach_timebase_info_data_t info = [] {
    mach_timebase_info_data_t i{};
    mach_timebase_info(&i);
    return i;
  }();
  return static_cast<int64_t>(mach_absolute_time() * info.numer / info.denom);
}

FILE* logFile() {
  static FILE* file = [] {
    const std::string dir =
        std::string(getenv("HOME")) + "/Library/Logs/aud_audio_vst3";
    mkdir(dir.c_str(), 0755);
    const std::string path =
        dir + "/host-" + std::to_string(getpid()) + ".jsonl";
    fprintf(stderr, "Host log: %s\n", path.c_str());
    return fopen(path.c_str(), "a");
  }();
  return file;
}

void logRecord(const char* kind, const std::string& fields = "") {
  std::string line = std::string("{\"kind\":\"") + kind +
                     "\",\"t\":" + std::to_string(nowNs());
  if (!fields.empty()) line += "," + fields;
  line += "}\n";
  fputs(line.c_str(), logFile());
  fflush(logFile());
  fputs(line.c_str(), stdout);
  fflush(stdout);
}

uint64_t footprintOf(pid_t pid) {
  rusage_info_v4 info{};
  if (proc_pid_rusage(pid, RUSAGE_INFO_V4,
                      reinterpret_cast<rusage_info_t*>(&info)) != 0) {
    return 0;
  }
  return info.ri_phys_footprint;
}

// The CPU time of a process in nanoseconds. proc_pid_rusage reports user
// and system time in mach ticks on Apple silicon.
uint64_t cpuOf(pid_t pid) {
  rusage_info_v4 info{};
  if (proc_pid_rusage(pid, RUSAGE_INFO_V4,
                      reinterpret_cast<rusage_info_t*>(&info)) != 0) {
    return 0;
  }
  static mach_timebase_info_data_t timebase = [] {
    mach_timebase_info_data_t t{};
    mach_timebase_info(&t);
    return t;
  }();
  return (info.ri_user_time + info.ri_system_time) * timebase.numer / timebase.denom;
}

std::vector<pid_t> children() {
  std::vector<pid_t> pids(256);
  const int count = proc_listchildpids(getpid(), pids.data(),
                                       static_cast<int>(pids.size() * sizeof(pid_t)));
  pids.resize(count > 0 ? static_cast<size_t>(count) : 0);
  return pids;
}

// Logs the footprint of this process and of every child.
void logMemory(const char* label) {
  const uint64_t own = footprintOf(getpid());
  uint64_t childSum = 0;
  std::string list;
  for (pid_t pid : children()) {
    const uint64_t bytes = footprintOf(pid);
    childSum += bytes;
    if (!list.empty()) list += ",";
    list += "{\"pid\":" + std::to_string(pid) +
            ",\"bytes\":" + std::to_string(bytes) +
            ",\"cpuNs\":" + std::to_string(cpuOf(pid)) + "}";
  }
  logRecord("memory", std::string("\"label\":\"") + label +
                          "\",\"host\":" + std::to_string(own) +
                          ",\"hostCpuNs\":" + std::to_string(cpuOf(getpid())) +
                          ",\"children\":" + std::to_string(childSum) +
                          ",\"total\":" + std::to_string(own + childSum) +
                          ",\"childList\":[" + list + "]");
}

// ............................................................................
// Host objects

class ComponentHandler : public IComponentHandler {
 public:
  explicit ComponentHandler(ParameterChangeTransfer& transfer)
      : transfer_(transfer) {}
  virtual ~ComponentHandler() = default;

  tresult PLUGIN_API beginEdit(ParamID) override { return kResultOk; }
  tresult PLUGIN_API performEdit(ParamID id, ParamValue value) override {
    transfer_.addChange(id, value, 0);
    return kResultOk;
  }
  tresult PLUGIN_API endEdit(ParamID) override { return kResultOk; }
  tresult PLUGIN_API restartComponent(int32) override { return kResultOk; }

  tresult PLUGIN_API queryInterface(const TUID iid, void** obj) override {
    QUERY_INTERFACE(iid, obj, FUnknown::iid, IComponentHandler)
    QUERY_INTERFACE(iid, obj, IComponentHandler::iid, IComponentHandler)
    *obj = nullptr;
    return kNoInterface;
  }
  uint32 PLUGIN_API addRef() override { return 1; }
  uint32 PLUGIN_API release() override { return 1; }

 private:
  ParameterChangeTransfer& transfer_;
};

struct Instance;

class PlugFrame : public IPlugFrame {
 public:
  explicit PlugFrame(Instance* instance) : instance_(instance) {}
  virtual ~PlugFrame() = default;
  tresult PLUGIN_API resizeView(IPlugView* view, ViewRect* newSize) override;
  tresult PLUGIN_API queryInterface(const TUID iid, void** obj) override {
    QUERY_INTERFACE(iid, obj, FUnknown::iid, IPlugFrame)
    QUERY_INTERFACE(iid, obj, IPlugFrame::iid, IPlugFrame)
    *obj = nullptr;
    return kNoInterface;
  }
  uint32 PLUGIN_API addRef() override { return 1; }
  uint32 PLUGIN_API release() override { return 1; }

 private:
  Instance* instance_;
};

struct Instance {
  std::string bundle;
  int index = 0;
  VST3::Hosting::Module::Ptr module;
  IPtr<PlugProvider> provider;
  IPtr<IComponent> component;
  IPtr<IAudioProcessor> processor;
  IPtr<IEditController> controller;
  HostProcessData data;
  ParameterChanges inputChanges{64};
  ParameterChangeTransfer transfer{256};
  std::unique_ptr<ComponentHandler> handler;
  std::unique_ptr<PlugFrame> frame;
  IPtr<IPlugView> view;
  NSWindow* window = nil;
  std::vector<float> left;
  std::vector<float> right;
  ParamID testParam = kNoParamId;
  ParamID cutoffParam = kNoParamId;
};

tresult PLUGIN_API PlugFrame::resizeView(IPlugView* view, ViewRect* newSize) {
  if (view == nullptr || newSize == nullptr || instance_->window == nil) {
    return kInvalidArgument;
  }
  [instance_->window
      setContentSize:NSMakeSize(newSize->getWidth(), newSize->getHeight())];
  view->onSize(newSize);
  return kResultTrue;
}

std::vector<std::unique_ptr<Instance>> instances;
HostApplication* hostApplication = nullptr;
AudioUnit outputUnit = nullptr;
std::atomic<bool> processing{false};
std::atomic<uint64_t> overloads{0};
// The device plays silence unless --audible: the plugins still render.
bool audible = false;

// ............................................................................
// Audio

void processAll(UInt32 frames, float* outLeft, float* outRight) {
  if (outLeft != nullptr) memset(outLeft, 0, frames * sizeof(float));
  if (outRight != nullptr) memset(outRight, 0, frames * sizeof(float));
  if (!processing.load(std::memory_order_acquire)) return;
  for (auto& instance : instances) {
    Instance& i = *instance;
    i.transfer.transferChangesTo(i.inputChanges);
    i.data.numSamples = static_cast<int32>(frames);
    i.data.inputParameterChanges = &i.inputChanges;
    float* channels[2] = {i.left.data(), i.right.data()};
    i.data.setChannelBuffers(kOutput, 0, channels, 2);
    i.processor->process(i.data);
    i.inputChanges.clearQueue();
    if (audible && outLeft != nullptr && outRight != nullptr) {
      for (UInt32 f = 0; f < frames; ++f) {
        outLeft[f] += i.left[f];
        outRight[f] += i.right[f];
      }
    }
  }
}

OSStatus renderCallback(void*, AudioUnitRenderActionFlags*,
                        const AudioTimeStamp*, UInt32, UInt32 frames,
                        AudioBufferList* buffers) {
  float* left = buffers->mNumberBuffers > 0
                    ? static_cast<float*>(buffers->mBuffers[0].mData)
                    : nullptr;
  float* right = buffers->mNumberBuffers > 1
                     ? static_cast<float*>(buffers->mBuffers[1].mData)
                     : nullptr;
  processAll(frames, left, right);
  return noErr;
}

OSStatus overloadListener(AudioObjectID, UInt32, const AudioObjectPropertyAddress*,
                          void*) {
  overloads.fetch_add(1, std::memory_order_relaxed);
  return noErr;
}

AudioObjectID defaultOutputDevice() {
  AudioObjectID device = kAudioObjectUnknown;
  UInt32 size = sizeof(device);
  AudioObjectPropertyAddress address = {kAudioHardwarePropertyDefaultOutputDevice,
                                        kAudioObjectPropertyScopeGlobal,
                                        kAudioObjectPropertyElementMain};
  AudioObjectGetPropertyData(kAudioObjectSystemObject, &address, 0, nullptr,
                             &size, &device);
  return device;
}

bool startAudio() {
  const AudioObjectID device = defaultOutputDevice();
  UInt32 frames = kBlockFrames;
  AudioObjectPropertyAddress bufferAddress = {
      kAudioDevicePropertyBufferFrameSize, kAudioObjectPropertyScopeGlobal,
      kAudioObjectPropertyElementMain};
  AudioObjectSetPropertyData(device, &bufferAddress, 0, nullptr, sizeof(frames),
                             &frames);
  AudioObjectPropertyAddress overloadAddress = {
      kAudioDeviceProcessorOverload, kAudioObjectPropertyScopeGlobal,
      kAudioObjectPropertyElementMain};
  AudioObjectAddPropertyListener(device, &overloadAddress, overloadListener,
                                 nullptr);
  AudioComponentDescription description = {kAudioUnitType_Output,
                                           kAudioUnitSubType_DefaultOutput,
                                           kAudioUnitManufacturer_Apple, 0, 0};
  AudioComponent component = AudioComponentFindNext(nullptr, &description);
  if (component == nullptr ||
      AudioComponentInstanceNew(component, &outputUnit) != noErr) {
    return false;
  }
  AudioStreamBasicDescription format = {};
  format.mSampleRate = kSampleRate;
  format.mFormatID = kAudioFormatLinearPCM;
  format.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked |
                        kAudioFormatFlagIsNonInterleaved;
  format.mBytesPerPacket = sizeof(float);
  format.mFramesPerPacket = 1;
  format.mBytesPerFrame = sizeof(float);
  format.mChannelsPerFrame = 2;
  format.mBitsPerChannel = 32;
  AudioUnitSetProperty(outputUnit, kAudioUnitProperty_StreamFormat,
                       kAudioUnitScope_Input, 0, &format, sizeof(format));
  UInt32 maxFrames = kMaxBlock;
  AudioUnitSetProperty(outputUnit, kAudioUnitProperty_MaximumFramesPerSlice,
                       kAudioUnitScope_Global, 0, &maxFrames, sizeof(maxFrames));
  AURenderCallbackStruct callback = {renderCallback, nullptr};
  AudioUnitSetProperty(outputUnit, kAudioUnitProperty_SetRenderCallback,
                       kAudioUnitScope_Input, 0, &callback, sizeof(callback));
  if (AudioUnitInitialize(outputUnit) != noErr) return false;
  return AudioOutputUnitStart(outputUnit) == noErr;
}

void stopAudio() {
  if (outputUnit == nullptr) return;
  AudioOutputUnitStop(outputUnit);
  AudioUnitUninitialize(outputUnit);
  AudioComponentInstanceDispose(outputUnit);
  outputUnit = nullptr;
}

std::atomic<bool> timerRunning{false};
std::thread timerThread;

// Without a device: process on a thread at the block period.
void startTimerAudio() {
  timerRunning = true;
  timerThread = std::thread([] {
    std::vector<float> left(kBlockFrames);
    std::vector<float> right(kBlockFrames);
    mach_timebase_info_data_t info{};
    mach_timebase_info(&info);
    const uint64_t period = static_cast<uint64_t>(
        kBlockFrames / kSampleRate * 1e9 * info.denom / info.numer);
    uint64_t next = mach_absolute_time();
    while (timerRunning) {
      processAll(kBlockFrames, left.data(), right.data());
      next += period;
      mach_wait_until(next);
    }
  });
}

// ............................................................................
// Plugins

ParamID findParam(IEditController* controller, const char* title) {
  const int32 count = controller->getParameterCount();
  for (int32 i = 0; i < count; ++i) {
    ParameterInfo info{};
    if (controller->getParameterInfo(i, info) != kResultOk) continue;
    char text[256] = {};
    for (int c = 0; c < 128 && info.title[c] != 0; ++c) {
      text[c] = static_cast<char>(info.title[c]);
    }
    if (strcmp(text, title) == 0) return info.id;
  }
  return kNoParamId;
}

bool loadInstance(Instance& instance) {
  std::string error;
  instance.module = VST3::Hosting::Module::create(instance.bundle, error);
  if (!instance.module) {
    fprintf(stderr, "Cannot load %s: %s\n", instance.bundle.c_str(),
            error.c_str());
    return false;
  }
  for (const auto& info : instance.module->getFactory().classInfos()) {
    if (info.category() != kVstAudioEffectClass) continue;
    instance.provider =
        owned(new PlugProvider(instance.module->getFactory(), info, true));
    break;
  }
  if (!instance.provider || !instance.provider->initialize()) return false;
  instance.component = instance.provider->getComponentPtr();
  instance.controller = instance.provider->getControllerPtr();
  instance.processor = U::cast<IAudioProcessor>(instance.component);
  if (!instance.processor || !instance.controller) return false;
  instance.handler = std::make_unique<ComponentHandler>(instance.transfer);
  instance.controller->setComponentHandler(instance.handler.get());
  instance.frame = std::make_unique<PlugFrame>(&instance);
  ProcessSetup setup{kRealtime, kSample32, kMaxBlock, kSampleRate};
  if (instance.processor->setupProcessing(setup) != kResultOk) return false;
  SpeakerArrangement stereo = SpeakerArr::kStereo;
  instance.processor->setBusArrangements(nullptr, 0, &stereo, 1);
  instance.component->activateBus(kAudio, kOutput, 0, true);
  instance.data.prepare(*instance.component, 0, kSample32);
  instance.left.resize(kMaxBlock);
  instance.right.resize(kMaxBlock);
  instance.component->setActive(true);
  instance.processor->setProcessing(true);
  instance.transfer.setMaxParameters(instance.controller->getParameterCount());
  instance.testParam = findParam(instance.controller, "Spike test");
  instance.cutoffParam = findParam(instance.controller, "filter Cutoff");
  logRecord("loaded", "\"instance\":" + std::to_string(instance.index) +
                          ",\"bundle\":\"" + instance.bundle + "\"");
  return true;
}

void unloadInstance(Instance& instance) {
  if (instance.processor) instance.processor->setProcessing(false);
  if (instance.component) instance.component->setActive(false);
  instance.data.unprepare();
  instance.controller = nullptr;
  instance.processor = nullptr;
  instance.component = nullptr;
  instance.provider = nullptr;
}

bool openEditor(Instance& instance) {
  if (instance.view) return true;
  const int64_t start = nowNs();
  instance.view = owned(instance.controller->createView(ViewType::kEditor));
  if (!instance.view) {
    logRecord("noEditor", "\"instance\":" + std::to_string(instance.index));
    return false;
  }
  ViewRect size{};
  instance.view->getSize(&size);
  NSWindowStyleMask style = NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                            NSWindowStyleMaskMiniaturizable;
  if (instance.view->canResize() == kResultTrue) {
    style |= NSWindowStyleMaskResizable;
  }
  const NSRect content =
      NSMakeRect(80 + instance.index * 40, 200 + instance.index * 260,
                 size.getWidth(), size.getHeight());
  instance.window = [[NSWindow alloc] initWithContentRect:content
                                                styleMask:style
                                                  backing:NSBackingStoreBuffered
                                                    defer:NO];
  instance.window.releasedWhenClosed = NO;
  instance.window.title = [NSString
      stringWithFormat:@"%s #%d", instance.bundle.c_str(), instance.index];
  instance.view->setFrame(instance.frame.get());
  if (instance.view->attached((__bridge void*)instance.window.contentView,
                              kPlatformTypeNSView) != kResultTrue) {
    logRecord("attachFailed", "\"instance\":" + std::to_string(instance.index));
    instance.view = nullptr;
    instance.window = nil;
    return false;
  }
  [instance.window makeKeyAndOrderFront:nil];
  logRecord("window", "\"instance\":" + std::to_string(instance.index) +
                          ",\"number\":" + std::to_string(instance.window.windowNumber));
  logRecord("opened", "\"instance\":" + std::to_string(instance.index) +
                          ",\"ns\":" + std::to_string(nowNs() - start));
  return true;
}

void closeEditor(Instance& instance) {
  if (!instance.view) return;
  const int64_t start = nowNs();
  instance.view->removed();
  instance.view->setFrame(nullptr);
  instance.view = nullptr;
  [instance.window close];
  instance.window = nil;
  logRecord("closed", "\"instance\":" + std::to_string(instance.index) +
                          ",\"ns\":" + std::to_string(nowNs() - start));
}

// Automation from the host: the controller on the UI thread, the processor
// through its next block - as a DAW plays an envelope.
void automate(Instance& instance, ParamID id, double value) {
  instance.controller->setParamNormalized(id, value);
  instance.transfer.addChange(id, value, 0);
}

// ............................................................................
// The UI thread watchdog: how late the main queue runs a block.

std::atomic<bool> watching{false};
std::atomic<int64_t> worstStallNs{0};
std::thread watchThread;

void startWatch() {
  watching = true;
  watchThread = std::thread([] {
    while (watching) {
      const int64_t posted = nowNs();
      dispatch_semaphore_t done = dispatch_semaphore_create(0);
      dispatch_async(dispatch_get_main_queue(), ^{
        const int64_t late = nowNs() - posted;
        int64_t worst = worstStallNs.load();
        while (late > worst && !worstStallNs.compare_exchange_weak(worst, late)) {
        }
        dispatch_semaphore_signal(done);
      });
      // Waits for the block, but never longer than a second per probe.
      dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 1000000000));
      usleep(10000);
    }
  });
}

void logStall(const char* label) {
  logRecord("stall", std::string("\"label\":\"") + label +
                         "\",\"worstNs\":" + std::to_string(worstStallNs.exchange(0)) +
                         ",\"overloads\":" + std::to_string(overloads.exchange(0)));
}

// ............................................................................
// Scenarios

struct Options {
  std::vector<std::string> bundles;
  int instances = 1;
  std::string scenario = "open";
  double duration = 0;
  int cycles = 100;
  bool audio = true;
  bool audible = false;
};

void after(double seconds, dispatch_block_t block) {
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                               static_cast<int64_t>(seconds * 1e9)),
                 dispatch_get_main_queue(), block);
}

void quit() {
  logStall("end");
  logMemory("end");
  for (auto& instance : instances) closeEditor(*instance);
  processing = false;
  stopAudio();
  if (timerRunning) {
    timerRunning = false;
    timerThread.join();
  }
  watching = false;
  if (watchThread.joinable()) watchThread.join();
  for (auto& instance : instances) unloadInstance(*instance);
  instances.clear();
  logRecord("quit");
  [NSApp terminate:nil];
}

void openAll() {
  for (auto& instance : instances) openEditor(*instance);
}

void runCycles(int remaining, int total) {
  if (remaining == 0) {
    after(2.0, ^{
      logMemory("cyclesDone");
      logRecord("cycleChildren",
                "\"count\":" + std::to_string(children().size()));
      quit();
    });
    return;
  }
  openAll();
  after(0.5, ^{
    for (auto& instance : instances) closeEditor(*instance);
    if ((total - remaining) % 10 == 0) logMemory("cycle");
    after(0.2, ^{ runCycles(remaining - 1, total); });
  });
}

void startTest() {
  for (auto& instance : instances) {
    if (instance->testParam == kNoParamId) continue;
    instance->controller->setParamNormalized(instance->testParam, 1);
    break;
  }
  after(20, ^{
    for (auto& instance : instances) {
      if (instance->testParam != kNoParamId) {
        instance->controller->setParamNormalized(instance->testParam, 0);
      }
    }
    logStall("test");
    logMemory("test");
    quit();
  });
}

void automateStep(int step) {
  Instance& instance = *instances.front();
  if (instance.cutoffParam == kNoParamId) {
    quit();
    return;
  }
  if (step > 1000) {
    logStall("automate");
    quit();
    return;
  }
  const double value =
      0.25 + (step <= 500 ? step : 1000 - step) * 0.0005;
  automate(instance, instance.cutoffParam, value);
  after(1.0 / 60, ^{ automateStep(step + 1); });
}

// Kills the first editor process, waits, reopens; then suspends one for
// ten seconds.
void crashScenario() {
  auto pids = children();
  if (pids.empty()) {
    logRecord("noChild");
    quit();
    return;
  }
  const pid_t first = pids.front();
  logRecord("kill", "\"pid\":" + std::to_string(first));
  kill(first, SIGKILL);
  after(3, ^{
    logStall("afterKill");
    for (auto& instance : instances) closeEditor(*instance);
    openAll();
    after(3, ^{
      auto again = children();
      if (again.empty()) {
        logRecord("noChildAfterReopen");
        quit();
        return;
      }
      const pid_t victim = again.front();
      logRecord("stop", "\"pid\":" + std::to_string(victim));
      kill(victim, SIGSTOP);
      after(10, ^{
        kill(victim, SIGCONT);
        logRecord("cont", "\"pid\":" + std::to_string(victim));
        after(3, ^{
          logStall("afterStop");
          quit();
        });
      });
    });
  });
}

void soakStep(int step, int total) {
  if (step >= total) {
    logStall("soak");
    quit();
    return;
  }
  for (auto& instance : instances) {
    if (instance->cutoffParam == kNoParamId) continue;
    const double phase = (step % 600) / 600.0;
    automate(*instance, instance->cutoffParam,
             0.3 + 0.2 * std::sin(phase * 2 * M_PI));
  }
  if (step % 1800 == 0) {
    logStall("soak");
    logMemory("soak");
  }
  after(1.0 / 30, ^{ soakStep(step + 1, total); });
}

void runScenario(const Options& options) {
  logMemory("loaded");
  const std::string& s = options.scenario;
  if (s == "closed") {
    after(5, ^{
      logMemory("closed");
      quit();
    });
  } else if (s == "open") {
    openAll();
    after(3, ^{ logMemory("open"); });
    if (options.duration > 0) after(options.duration, ^{ quit(); });
  } else if (s == "test") {
    openAll();
    after(3, ^{
      logMemory("open");
      startTest();
    });
  } else if (s == "automate") {
    openAll();
    after(3, ^{ automateStep(0); });
  } else if (s == "cycles") {
    const int cycles = options.cycles;
    after(1, ^{ runCycles(cycles, cycles); });
  } else if (s == "crash") {
    openAll();
    after(3, ^{ crashScenario(); });
  } else if (s == "pair") {
    // Two plugins: both editors open, the first closes, the others go on.
    openAll();
    after(4, ^{
      logRecord("closeFirst");
      closeEditor(*instances.front());
      after(4, ^{ quit(); });
    });
  } else if (s == "soak") {
    openAll();
    const int total = static_cast<int>((options.duration > 0 ? options.duration : 600) * 30);
    after(3, ^{ soakStep(0, total); });
  } else {
    fprintf(stderr, "Unknown scenario %s\n", s.c_str());
    quit();
  }
}

Options parseOptions(int argc, const char* argv[]) {
  Options options;
  for (int i = 1; i < argc; ++i) {
    const std::string arg = argv[i];
    auto next = [&]() { return i + 1 < argc ? std::string(argv[++i]) : std::string(); };
    if (arg == "--plugin") options.bundles.push_back(next());
    else if (arg == "--instances") options.instances = std::stoi(next());
    else if (arg == "--scenario") options.scenario = next();
    else if (arg == "--duration") options.duration = std::stod(next());
    else if (arg == "--cycles") options.cycles = std::stoi(next());
    else if (arg == "--no-audio") options.audio = false;
    else if (arg == "--audible") options.audible = true;
  }
  return options;
}

}  // namespace

// --measure <pid>: one JSON line with the footprint and the CPU time of a
// process and of its children, for processes the host did not start
// (REAPER, Live).
int measure(pid_t pid) {
  std::vector<pid_t> pids(256);
  const int count = proc_listchildpids(pid, pids.data(),
                                       static_cast<int>(pids.size() * sizeof(pid_t)));
  pids.resize(count > 0 ? static_cast<size_t>(count) : 0);
  std::string list;
  uint64_t childSum = 0;
  for (pid_t child : pids) {
    const uint64_t bytes = footprintOf(child);
    childSum += bytes;
    if (!list.empty()) list += ",";
    list += "{\"pid\":" + std::to_string(child) + ",\"bytes\":" + std::to_string(bytes) +
            ",\"cpuNs\":" + std::to_string(cpuOf(child)) + "}";
  }
  printf("{\"kind\":\"measure\",\"t\":%lld,\"pid\":%d,\"bytes\":%llu,\"cpuNs\":%llu,"
         "\"children\":%llu,\"childList\":[%s]}\n",
         static_cast<long long>(nowNs()), pid, static_cast<unsigned long long>(footprintOf(pid)),
         static_cast<unsigned long long>(cpuOf(pid)), static_cast<unsigned long long>(childSum),
         list.c_str());
  return 0;
}

// --session: one JSON line on the display and the screen lock, for the
// runs in a DAW (scripts/reaper.js): the editors draw no frames while the
// display sleeps or the screen is locked.
int session() {
  bool locked = false;
  CFDictionaryRef current = CGSessionCopyCurrentDictionary();
  if (current != nullptr) {
    const void* value = CFDictionaryGetValue(current, CFSTR("CGSSessionScreenIsLocked"));
    locked = value != nullptr && CFGetTypeID(value) == CFBooleanGetTypeID() &&
             CFBooleanGetValue(static_cast<CFBooleanRef>(value));
    CFRelease(current);
  }
  printf("{\"kind\":\"session\",\"displayAsleep\":%s,\"screenLocked\":%s}\n",
         CGDisplayIsAsleep(CGMainDisplayID()) ? "true" : "false", locked ? "true" : "false");
  return 0;
}

int main(int argc, const char* argv[]) {
  if (argc == 3 && std::string(argv[1]) == "--measure") return measure(std::stoi(argv[2]));
  if (argc == 2 && std::string(argv[1]) == "--session") return session();
  @autoreleasepool {
    const Options options = parseOptions(argc, argv);
    if (options.bundles.empty()) {
      fprintf(stderr,
              "usage: aud_spike_host --plugin <bundle> [--plugin <bundle>] "
              "[--instances n] [--scenario s] [--duration s] [--cycles n] "
              "[--no-audio]\n");
      return 2;
    }
    [NSApplication sharedApplication];
    [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
    hostApplication = new HostApplication();
    PluginContextFactory::instance().setPluginContext(hostApplication);
    logRecord("start", "\"scenario\":\"" + options.scenario + "\"");
    int index = 0;
    for (const std::string& bundle : options.bundles) {
      for (int n = 0; n < options.instances; ++n) {
        auto instance = std::make_unique<Instance>();
        instance->bundle = bundle;
        instance->index = index++;
        if (!loadInstance(*instance)) return 1;
        instances.push_back(std::move(instance));
      }
    }
    audible = options.audible;
    processing = true;
    if (!options.audio || !startAudio()) startTimerAudio();
    startWatch();
    [NSApp activateIgnoringOtherApps:YES];
    after(0.5, ^{ runScenario(options); });
    [NSApp run];
  }
  return 0;
}
