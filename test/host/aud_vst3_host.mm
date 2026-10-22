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
// With --editor s the host also shows the plugin's editor, in a window
// that does not take the focus, for at most s seconds: the editor's frames
// arrive (written as PNG with --snapshot <png>), and a click at --click x,y
// (points of the view) sends the editor's notes to the DAW on the plugin's
// event output and lets the editor draw the pressed button; --clicks n
// repeats it, --click-pause s waits between the clicks, and --cover lays the
// host's window over the editor's own window first, as a DAW's plugin
// window does. --hold-surfaces keeps every surface the view showed in use,
// as another process may, for --hold-seconds s (until the end without): the
// editor has to replace its surfaces to go on. --resize-steps n resizes the
// view live in n steps: the editor lives on and draws. --kill-editor ends
// the editor while a note is held: the plugin ends the note itself.
// --reframe resizes the view without onSize, as Cubase's full screen mode
// does: the editor follows. --occlude covers the plugin's window: the
// editor still draws.
//
//   aud_vst3_host <bundle.vst3> [--wav <dir>] [--presets n]
//     [--realtime-seconds s] [--editor s [--snapshot <png>] [--click x,y]
//     [--clicks n] [--click-pause s] [--cover] [--hold-surfaces
//     [--hold-seconds s]] [--resize-steps n] [--kill-editor] [--reframe]
//     [--occlude]]

#import <Cocoa/Cocoa.h>
#import <ImageIO/ImageIO.h>
#import <IOSurface/IOSurface.h>
#import <QuartzCore/QuartzCore.h>
#include <libproc.h>
#include <mach/mach_time.h>
#include <signal.h>
#include <unistd.h>

#include <algorithm>
#include <cmath>
#include <functional>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

#include "pluginterfaces/base/ibstream.h"
#include "pluginterfaces/gui/iplugview.h"
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
    component_->activateBus(kEvent, kOutput, 0, true);
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
    data.outputEvents = &output_;
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

  // The notes the plugin sent to the DAW since the last call, as
  // "channel:pitch" with channels from 1; the note offs go to `offs`.
  std::vector<std::string> takeNoteOns(std::vector<std::string>* offs = nullptr) {
    std::vector<std::string> notes;
    for (int32 i = 0; i < output_.getEventCount(); ++i) {
      Event e{};
      if (output_.getEvent(i, e) != kResultOk) continue;
      if (e.type == Event::kNoteOnEvent) {
        notes.push_back(std::to_string(e.noteOn.channel + 1) + ":" +
                        std::to_string(e.noteOn.pitch));
      } else if (e.type == Event::kNoteOffEvent && offs != nullptr) {
        offs->push_back(std::to_string(e.noteOff.channel + 1) + ":" +
                        std::to_string(e.noteOff.pitch));
      }
    }
    output_.clear();
    return notes;
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
  EventList output_{256};
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

// The frame the plugin's view shows: the IOSurface its layer holds, nil
// before the first frame.
IOSurfaceRef shownSurface(NSWindow* window) {
  NSView* view = window.contentView.subviews.firstObject;
  CALayer* surface = view.layer.sublayers.firstObject;
  id contents = surface.contents;
  if (contents == nil ||
      CFGetTypeID((__bridge CFTypeRef)contents) != IOSurfaceGetTypeID()) {
    return nullptr;
  }
  return (__bridge IOSurfaceRef)contents;
}

// Whether the frame shows more than one color: the editor drew its widgets.
bool drawn(IOSurfaceRef surface) {
  IOSurfaceLock(surface, kIOSurfaceLockReadOnly, nullptr);
  const auto* base = static_cast<const uint8_t*>(IOSurfaceGetBaseAddress(surface));
  const size_t rowBytes = IOSurfaceGetBytesPerRow(surface);
  const size_t width = IOSurfaceGetWidth(surface);
  const size_t height = IOSurfaceGetHeight(surface);
  uint32_t first = 0;
  std::memcpy(&first, base, 4);
  bool varied = false;
  for (size_t y = 0; y < height && !varied; y += 4) {
    const auto* row = reinterpret_cast<const uint32_t*>(base + y * rowBytes);
    for (size_t x = 0; x < width; x += 4) {
      if (row[x] != first) {
        varied = true;
        break;
      }
    }
  }
  IOSurfaceUnlock(surface, kIOSurfaceLockReadOnly, nullptr);
  return varied;
}

// The four characters of a pixel format, e.g. BGRA.
std::string fourCc(OSType format) {
  std::string out;
  for (int shift = 24; shift >= 0; shift -= 8) out += static_cast<char>((format >> shift) & 0xff);
  return out;
}

// Writes the frame `surface` as PNG to `path`: 8-bit BGRA, or the 10-bit
// extended range BGRA of Impeller (w40a: 16 bits per component, the value
// in the upper 10, 384 for 0.0 and 894 for 1.0).
bool writePng(IOSurfaceRef surface, const std::string& path) {
  const OSType format = IOSurfaceGetPixelFormat(surface);
  if (format != 'BGRA' && format != 'w40a') return false;
  const size_t width = IOSurfaceGetWidth(surface);
  const size_t height = IOSurfaceGetHeight(surface);
  std::vector<uint8_t> rgba(width * height * 4);
  IOSurfaceLock(surface, kIOSurfaceLockReadOnly, nullptr);
  const auto* base = static_cast<const uint8_t*>(IOSurfaceGetBaseAddress(surface));
  const size_t rowBytes = IOSurfaceGetBytesPerRow(surface);
  for (size_t y = 0; y < height; ++y) {
    for (size_t x = 0; x < width; ++x) {
      uint8_t* out = &rgba[(y * width + x) * 4];
      if (format == 'BGRA') {
        const uint8_t* in = base + y * rowBytes + x * 4;
        out[0] = in[2];
        out[1] = in[1];
        out[2] = in[0];
        out[3] = in[3];
        continue;
      }
      const auto* in = reinterpret_cast<const uint16_t*>(base + y * rowBytes + x * 8);
      auto unit = [](uint16_t v) {
        const double value = ((v >> 6) - 384.0) / 510.0;
        return static_cast<uint8_t>(std::lround(std::clamp(value, 0.0, 1.0) * 255));
      };
      out[0] = unit(in[2]);
      out[1] = unit(in[1]);
      out[2] = unit(in[0]);
      out[3] = unit(in[3]);
    }
  }
  IOSurfaceUnlock(surface, kIOSurfaceLockReadOnly, nullptr);
  CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
  CGContextRef context = CGBitmapContextCreate(
      rgba.data(), width, height, 8, width * 4, space,
      kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
  CGImageRef image = context != nullptr ? CGBitmapContextCreateImage(context) : nullptr;
  bool ok = false;
  if (image != nullptr) {
    NSURL* url = [NSURL fileURLWithPath:@(path.c_str())];
    CGImageDestinationRef file = CGImageDestinationCreateWithURL(
        (__bridge CFURLRef)url, CFSTR("public.png"), 1, nullptr);
    if (file != nullptr) {
      CGImageDestinationAddImage(file, image, nullptr);
      ok = CGImageDestinationFinalize(file);
      CFRelease(file);
    }
    CGImageRelease(image);
  }
  if (context != nullptr) CGContextRelease(context);
  CGColorSpaceRelease(space);
  return ok;
}

// A mouse event of `type` at `point` of `window`'s content.
NSEvent* mouseEvent(NSEventType type, NSWindow* window, NSPoint point) {
  return [NSEvent mouseEventWithType:type
                            location:point
                       modifierFlags:0
                           timestamp:NSProcessInfo.processInfo.systemUptime
                        windowNumber:window.windowNumber
                             context:nil
                         eventNumber:0
                          clickCount:1
                            pressure:type == NSEventTypeLeftMouseUp ? 0 : 1];
}

// The editor process the plugin started, 0 when there is none.
pid_t editorPid() {
  pid_t children[64];
  // The number of children, not of bytes.
  const int count = proc_listchildpids(getpid(), children, sizeof(children));
  for (int i = 0; i < count; ++i) {
    char path[PROC_PIDPATHINFO_MAXSIZE];
    if (proc_pidpath(children[i], path, sizeof(path)) > 0 &&
        std::strstr(path, "/Contents/Helpers/") != nullptr) {
      return children[i];
    }
  }
  return 0;
}

// Shows the plugin's editor as a DAW does and checks that its frames
// arrive and that a click at (clickX, clickY) plays notes to the DAW.
void checkEditor(Instance& instance, double seconds, const std::string& snapshot,
                 bool click, double clickX, double clickY, int clicks, double clickPause,
                 bool cover, bool holdSurfaces, double holdSeconds, int resizeSteps,
                 bool killEditor, bool reframe, bool occlude) {
  IPtr<IPlugView> view = owned(instance.controller()->createView(ViewType::kEditor));
  if (!view || view->isPlatformTypeSupported(kPlatformTypeNSView) != kResultTrue) {
    report("editor", false, "\"error\":\"no NSView editor\"");
    return;
  }
  ViewRect size{};
  view->getSize(&size);
  [NSApplication sharedApplication];
  // No Dock icon and no focus: the window shows without taking the screen.
  [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
  [NSApp finishLaunching];
  const NSRect screen = NSScreen.mainScreen.visibleFrame;
  const NSRect frame = NSMakeRect(NSMaxX(screen) - size.getWidth() - 16,
                                  NSMinY(screen) + 16, size.getWidth(),
                                  size.getHeight());
  NSWindow* window = [[NSWindow alloc] initWithContentRect:frame
                                                 styleMask:NSWindowStyleMaskTitled
                                                   backing:NSBackingStoreBuffered
                                                     defer:NO];
  window.releasedWhenClosed = NO;
  window.title = @"aud_vst3_host";
  [window orderFrontRegardless];
  instance.start(kRealtime, kBlock);
  view->attached((__bridge void*)window.contentView, kPlatformTypeNSView);

  // Pumps the window's events and renders blocks in realtime for `wait`
  // seconds or until `done` holds.
  const double blockSeconds = kBlock / kSampleRate;
  double rendered = nowSeconds();
  std::vector<std::string> notes;
  std::vector<std::string> offs;
  // The surfaces the host keeps in use (--hold-surfaces), with the time it
  // took them.
  std::vector<std::pair<IOSurfaceRef, double>> held;
  size_t heldCount = 0;
  auto let = [](IOSurfaceRef surface) {
    IOSurfaceDecrementUseCount(surface);
    CFRelease(surface);
  };
  auto hold = [&] {
    if (!holdSurfaces) return;
    const double now = nowSeconds();
    if (holdSeconds > 0) {
      for (auto it = held.begin(); it != held.end();) {
        if (now - it->second >= holdSeconds) {
          let(it->first);
          it = held.erase(it);
        } else {
          ++it;
        }
      }
    }
    IOSurfaceRef shown = shownSurface(window);
    if (shown == nullptr) return;
    for (const auto& entry : held) {
      if (entry.first == shown) return;
    }
    CFRetain(shown);
    IOSurfaceIncrementUseCount(shown);
    held.emplace_back(shown, now);
    heldCount += 1;
  };
  auto pump = [&](double wait, const std::function<bool()>& done) {
    const double end = nowSeconds() + wait;
    while (nowSeconds() < end && !done()) {
      hold();
      NSEvent* event = [NSApp nextEventMatchingMask:NSEventMaskAny
                                          untilDate:[NSDate dateWithTimeIntervalSinceNow:0.005]
                                             inMode:NSDefaultRunLoopMode
                                            dequeue:YES];
      if (event != nil) [NSApp sendEvent:event];
      while (rendered + blockSeconds <= nowSeconds()) {
        instance.process();
        for (const auto& note : instance.takeNoteOns(&offs)) notes.push_back(note);
        rendered += blockSeconds;
      }
    }
  };

  const double start = nowSeconds();
  pump(seconds, [&] {
    IOSurfaceRef surface = shownSurface(window);
    return surface != nullptr && drawn(surface);
  });
  IOSurfaceRef surface = shownSurface(window);
  const bool framed = surface != nullptr && drawn(surface);
  report("editor", framed,
         "\"ms\":" + std::to_string((nowSeconds() - start) * 1000) +
             ",\"width\":" + std::to_string(size.getWidth()) +
             ",\"height\":" + std::to_string(size.getHeight()));

  if (framed && click) {
    // As a DAW's plugin window does once the DAW is active again: the
    // host's window lies over the editor's own window.
    if (cover) [window orderFrontRegardless];
    // The view is flipped and fills the content: y counts from the top.
    NSView* pluginView = window.contentView.subviews.firstObject;
    const NSPoint point = NSMakePoint(clickX, size.getHeight() - clickY);
    // The frame shown now: its surface and the seed of its content.
    auto shown = [&] {
      IOSurfaceRef now = shownSurface(window);
      return now == nullptr ? std::pair<uint32_t, uint32_t>{0, 0}
                            : std::pair<uint32_t, uint32_t>{IOSurfaceGetID(now),
                                                            IOSurfaceGetSeed(now)};
    };
    int played = 0;
    int redrawn = 0;
    int firstStill = -1;
    std::string chord;
    for (int i = 0; i < clicks; ++i) {
      notes.clear();
      const auto before = shown();
      [pluginView mouseDown:mouseEvent(NSEventTypeLeftMouseDown, window, point)];
      // A pressed button lights up: the editor draws a new frame.
      pump(0.4, [&] { return shown() != before; });
      const bool redraw = shown() != before;
      pump(0.1, [] { return false; });
      [pluginView mouseUp:mouseEvent(NSEventTypeLeftMouseUp, window, point)];
      pump(2, [&] { return !notes.empty(); });
      // The rest of the chord follows within a few blocks.
      pump(0.3, [] { return false; });
      if (!notes.empty()) played += 1;
      if (redraw) redrawn += 1;
      else if (firstStill < 0) firstStill = i;
      if (i == 0) {
        for (const auto& note : notes) chord += (chord.empty() ? "\"" : ",\"") + note + "\"";
      }
      pump(clickPause, [] { return false; });
    }
    report("editorMidi", played == clicks,
           "\"clicks\":" + std::to_string(clicks) + ",\"played\":" +
               std::to_string(played) + ",\"notes\":[" + chord + "]");
    report("editorRedraw", redrawn == clicks,
           "\"clicks\":" + std::to_string(clicks) + ",\"redrawn\":" +
               std::to_string(redrawn) + ",\"firstStill\":" + std::to_string(firstStill));
  }
  // A live resize as a DAW does it: the window changes size step by step,
  // and the view hears of every step. The editor lives on and draws.
  if (framed && resizeSteps > 0) {
    const pid_t before = editorPid();
    NSView* pluginView = window.contentView.subviews.firstObject;
    for (int i = 0; i < resizeSteps; ++i) {
      const int32 grow = (i % 20 < 10 ? i % 20 : 20 - i % 20) * 12;
      ViewRect rect(0, 0, size.getWidth() + grow, size.getHeight() + grow / 2);
      [window setContentSize:NSMakeSize(rect.getWidth(), rect.getHeight())];
      view->onSize(&rect);
      pump(0.008, [] { return false; });
    }
    ViewRect back = size;
    [window setContentSize:NSMakeSize(back.getWidth(), back.getHeight())];
    view->onSize(&back);
    pump(1, [] { return false; });
    const pid_t after = editorPid();
    IOSurfaceRef shownNow = shownSurface(window);
    const uint32_t seed = shownNow != nullptr ? IOSurfaceGetSeed(shownNow) : 0;
    const uint32_t id = shownNow != nullptr ? IOSurfaceGetID(shownNow) : 0;
    const NSPoint point = NSMakePoint(clickX, size.getHeight() - clickY);
    [pluginView mouseDown:mouseEvent(NSEventTypeLeftMouseDown, window, point)];
    pump(0.6, [&] {
      IOSurfaceRef now = shownSurface(window);
      return now != nullptr && (IOSurfaceGetID(now) != id || IOSurfaceGetSeed(now) != seed);
    });
    IOSurfaceRef now = shownSurface(window);
    const bool redraw =
        now != nullptr && (IOSurfaceGetID(now) != id || IOSurfaceGetSeed(now) != seed);
    [pluginView mouseUp:mouseEvent(NSEventTypeLeftMouseUp, window, point)];
    pump(0.3, [] { return false; });
    report("editorResize", before > 0 && before == after && redraw,
           "\"steps\":" + std::to_string(resizeSteps) + ",\"sameEditor\":" +
               (before > 0 && before == after ? "true" : "false") + ",\"redraw\":" +
               (redraw ? "true" : "false"));
  }

  // The view changes its size without onSize, as Cubase's full screen mode
  // does: the editor follows within a few checks of the plugin.
  if (framed && reframe) {
    NSView* pluginView = window.contentView.subviews.firstObject;
    const double scale = window.backingScaleFactor;
    const NSSize grown = NSMakeSize(size.getWidth() + 160, size.getHeight() + 80);
    [window setContentSize:grown];
    [pluginView setFrame:NSMakeRect(0, 0, grown.width, grown.height)];
    const size_t want = static_cast<size_t>(grown.width * scale);
    pump(2, [&] {
      IOSurfaceRef now = shownSurface(window);
      return now != nullptr && IOSurfaceGetWidth(now) == want;
    });
    IOSurfaceRef now = shownSurface(window);
    const size_t got = now != nullptr ? IOSurfaceGetWidth(now) : 0;
    report("editorReframe", got == want,
           "\"want\":" + std::to_string(want) + ",\"got\":" + std::to_string(got));
    [window setContentSize:NSMakeSize(size.getWidth(), size.getHeight())];
    [pluginView setFrame:NSMakeRect(0, 0, size.getWidth(), size.getHeight())];
    pump(1, [] { return false; });
  }

  // A window covers the plugin's window: the editor still draws.
  if (framed && occlude) {
    NSWindow* cover = [[NSWindow alloc] initWithContentRect:NSInsetRect(window.frame, -8, -8)
                                                  styleMask:NSWindowStyleMaskBorderless
                                                    backing:NSBackingStoreBuffered
                                                      defer:NO];
    cover.releasedWhenClosed = NO;
    cover.backgroundColor = NSColor.grayColor;
    cover.opaque = YES;
    [cover orderFrontRegardless];
    pump(1, [] { return false; });
    NSView* pluginView = window.contentView.subviews.firstObject;
    const NSPoint point = NSMakePoint(clickX, size.getHeight() - clickY);
    IOSurfaceRef before = shownSurface(window);
    const uint32_t id = before != nullptr ? IOSurfaceGetID(before) : 0;
    const uint32_t seed = before != nullptr ? IOSurfaceGetSeed(before) : 0;
    notes.clear();
    [pluginView mouseDown:mouseEvent(NSEventTypeLeftMouseDown, window, point)];
    pump(0.6, [&] {
      IOSurfaceRef now = shownSurface(window);
      return now != nullptr && (IOSurfaceGetID(now) != id || IOSurfaceGetSeed(now) != seed);
    });
    IOSurfaceRef now = shownSurface(window);
    const bool redraw =
        now != nullptr && (IOSurfaceGetID(now) != id || IOSurfaceGetSeed(now) != seed);
    [pluginView mouseUp:mouseEvent(NSEventTypeLeftMouseUp, window, point)];
    pump(0.3, [] { return false; });
    const size_t played = notes.size();
    [cover close];
    pump(0.3, [] { return false; });
    report("editorOccluded", redraw,
           std::string("\"redraw\":") + (redraw ? "true" : "false") + ",\"notes\":" +
               std::to_string(played));
  }

  // The editor ends while a note is held: the plugin ends the note itself,
  // in the graph and towards the DAW.
  if (framed && killEditor) {
    NSView* pluginView = window.contentView.subviews.firstObject;
    const NSPoint point = NSMakePoint(clickX, size.getHeight() - clickY);
    notes.clear();
    offs.clear();
    [pluginView mouseDown:mouseEvent(NSEventTypeLeftMouseDown, window, point)];
    pump(2, [&] { return !notes.empty(); });
    pump(0.3, [] { return false; });
    const std::vector<std::string> held = notes;
    const pid_t pid = editorPid();
    if (pid > 0) kill(pid, SIGKILL);
    pump(1.5, [&] { return offs.size() >= held.size() && !held.empty(); });
    bool all = !held.empty();
    for (const auto& note : held) {
      if (std::find(offs.begin(), offs.end(), note) == offs.end()) all = false;
    }
    [pluginView mouseUp:mouseEvent(NSEventTypeLeftMouseUp, window, point)];
    report("editorNotesReleased", all,
           "\"held\":" + std::to_string(held.size()) + ",\"ended\":" +
               std::to_string(offs.size()));
  }

  // Lets the last frame arrive before it is written.
  pump(0.5, [] { return false; });
  surface = shownSurface(window);
  if (!snapshot.empty() && surface != nullptr) {
    report("snapshot", writePng(surface, snapshot),
           "\"path\":\"" + snapshot + "\",\"format\":\"" +
               fourCc(IOSurfaceGetPixelFormat(surface)) + "\"");
  }
  if (holdSurfaces) {
    report("heldSurfaces", true, "\"count\":" + std::to_string(heldCount));
  }
  for (const auto& entry : held) let(entry.first);
  view->removed();
  view = nullptr;
  instance.stop();
  [window close];
}

}  // namespace

int main(int argc, char** argv) {
  if (argc < 2) {
    std::fprintf(stderr, "usage: aud_vst3_host <bundle.vst3> [--wav <dir>] "
                         "[--presets n] [--realtime-seconds s] [--editor s "
                         "[--snapshot <png>] [--click x,y] [--clicks n] "
                         "[--click-pause s] [--cover] [--hold-surfaces "
                         "[--hold-seconds s]] [--resize-steps n] [--kill-editor] "
                         "[--reframe] [--occlude]]\n");
    return 2;
  }
  const std::string bundle = argv[1];
  std::string wavDir;
  int32 maxPresets = 1 << 30;
  double realtimeSeconds = 5;
  double editorSeconds = 0;
  std::string snapshot;
  bool click = false;
  double clickX = 0, clickY = 0;
  int clicks = 1;
  double clickPause = 0;
  bool cover = false;
  bool holdSurfaces = false;
  double holdSeconds = 0;
  int resizeSteps = 0;
  bool killEditor = false;
  bool reframe = false;
  bool occlude = false;
  for (int i = 2; i < argc; ++i) {
    const std::string arg = argv[i];
    if (arg == "--wav" && i + 1 < argc) wavDir = argv[++i];
    else if (arg == "--presets" && i + 1 < argc) maxPresets = std::atoi(argv[++i]);
    else if (arg == "--realtime-seconds" && i + 1 < argc) realtimeSeconds = std::atof(argv[++i]);
    else if (arg == "--editor" && i + 1 < argc) editorSeconds = std::atof(argv[++i]);
    else if (arg == "--snapshot" && i + 1 < argc) snapshot = argv[++i];
    else if (arg == "--clicks" && i + 1 < argc) clicks = std::max(1, std::atoi(argv[++i]));
    else if (arg == "--click-pause" && i + 1 < argc) clickPause = std::atof(argv[++i]);
    else if (arg == "--cover") cover = true;
    else if (arg == "--hold-surfaces") holdSurfaces = true;
    else if (arg == "--hold-seconds" && i + 1 < argc) holdSeconds = std::atof(argv[++i]);
    else if (arg == "--resize-steps" && i + 1 < argc) resizeSteps = std::atoi(argv[++i]);
    else if (arg == "--kill-editor") killEditor = true;
    else if (arg == "--reframe") reframe = true;
    else if (arg == "--occlude") occlude = true;
    else if (arg == "--click" && i + 1 < argc) {
      click = std::sscanf(argv[++i], "%lf,%lf", &clickX, &clickY) == 2;
    }
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

  if (editorSeconds > 0) {
    checkEditor(a, editorSeconds, snapshot, click, clickX, clickY, clicks, clickPause,
                cover, holdSurfaces, holdSeconds, resizeSteps, killEditor, reframe, occlude);
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
