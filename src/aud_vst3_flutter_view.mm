// @license
// Copyright (c) Audanika. All Rights Reserved.
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

// Variant B of the spike (ticket 24): the Flutter editor in the DAW
// process. The bundle carries a copy of FlutterMacOS.framework whose name,
// Objective-C classes and Swift module start with a per-build prefix
// (AUD_VST3_FLUTTER_PREFIX, scripts/build-plugin.js), and the editor's AOT
// framework. The plugin loads them when the first editor opens - nothing of
// Flutter before - and gives every editor an engine of its own, whose view
// sits inside the plugin's view. The plugin and Dart talk over the method
// channel aud_vst3/plugin.
//
// Since Flutter 3.47 merges the platform and UI threads on macOS, Dart runs
// on the host's UI thread here (finding of the plan).

#import <Cocoa/Cocoa.h>
#import <QuartzCore/QuartzCore.h>
#include <dlfcn.h>
#import <objc/runtime.h>

#include <string>

#include "aud_audio_graph.h"
#include "aud_json.hpp"
#include "public.sdk/source/common/pluginview.h"

#include "aud_vst3_driver.hpp"
#include "aud_vst3_layout.hpp"
#include "aud_vst3_objc.hpp"
#include "aud_vst3_plugin.hpp"
#include "aud_vst3_probe.hpp"
#include "aud_vst3_shell.hpp"

#ifndef AUD_VST3_FLUTTER_PREFIX
#define AUD_VST3_FLUTTER_PREFIX "Flutter"
#endif

// #############################################################################
// What the plugin calls of FlutterDartProject. The classes of the Flutter
// API have renamed names, so the plugin reaches them through the runtime,
// with these protocols.
@protocol AudFlutterProject
- (instancetype)initWithPrecompiledDartBundle:(NSBundle*)bundle;
- (void)setDartEntrypointArguments:(NSArray<NSString*>*)arguments;
@end

// #############################################################################
// What the plugin calls of FlutterEngine.
@protocol AudFlutterEngine
- (instancetype)initWithName:(NSString*)name
                     project:(id)project
      allowHeadlessExecution:(BOOL)allowHeadlessExecution;
- (BOOL)runWithEntrypoint:(NSString*)entrypoint;
- (id)binaryMessenger;
- (void)shutDownEngine;
@end

// #############################################################################
// What the plugin calls of FlutterViewController.
@protocol AudFlutterViewController
- (instancetype)initWithEngine:(id)engine nibName:(NSString*)nibName bundle:(NSBundle*)bundle;
@end

// #############################################################################
// What the plugin reads of FlutterMethodCall.
@protocol AudFlutterMethodCall
- (NSString*)method;
- (id)arguments;
@end

// #############################################################################
// What the plugin calls of FlutterMethodChannel.
@protocol AudFlutterMethodChannel
+ (instancetype)methodChannelWithName:(NSString*)name binaryMessenger:(id)messenger;
- (void)setMethodCallHandler:(void (^)(id<AudFlutterMethodCall> call,
                                      void (^result)(id)))handler;
- (void)invokeMethod:(NSString*)method arguments:(id)arguments;
@end

namespace aud_vst3 {

using namespace Steinberg;

namespace {

// How long the controller and the engine of a closed editor live on:
// Flutter may still run a present it scheduled for a later vsync.
constexpr int64_t kEngineShutdownDelayNs = 200 * NSEC_PER_MSEC;

Class flutterClass(const char* suffix) {
  return objc_getClass((std::string(AUD_VST3_FLUTTER_PREFIX) + suffix).c_str());
}

// Loads the renamed framework once; false when it is missing.
bool loadFlutter(Probe& probe) {
  static bool loaded = false;
  if (loaded) return true;
  const int64_t start = nowNs();
  const std::string name = std::string(AUD_VST3_FLUTTER_PREFIX) + "MacOS";
  const std::string path = bundlePath() + "/Contents/Frameworks/" + name +
                           ".framework/Versions/A/" + name;
  if (dlopen(path.c_str(), RTLD_NOW | RTLD_LOCAL) == nullptr) {
    probe.write("error", std::string("\"message\":\"dlopen ") + dlerror() + "\"");
    return false;
  }
  loaded = flutterClass("Engine") != nil;
  probe.write("flutterLoaded", "\"ns\":" + std::to_string(nowNs() - start) +
                                   ",\"prefix\":\"" AUD_VST3_FLUTTER_PREFIX "\"");
  return loaded;
}

NSNumber* boxed(double value) { return @(value); }

// `text` as a string; an empty one for bytes that are no UTF-8.
NSString* stringOf(const std::string& text) {
  return [NSString stringWithUTF8String:text.c_str()] ?: @"";
}

// `json` as the objects of the method channel's codec. Integers become
// integer numbers, as in the JSON text the socket of A, S and F carries.
id foundationOf(const aud::Json& json) {
  switch (json.kind) {
    case aud::Json::Kind::null:
      return [NSNull null];
    case aud::Json::Kind::boolean:
      return json.boolean ? @YES : @NO;
    case aud::Json::Kind::number:
      return json.isInteger() ? @(json.integer()) : @(json.number);
    case aud::Json::Kind::string:
      return stringOf(json.string);
    case aud::Json::Kind::array: {
      NSMutableArray* array = [NSMutableArray array];
      for (const aud::Json& item : json.array) {
        [array addObject:foundationOf(item)];
      }
      return array;
    }
    case aud::Json::Kind::object: {
      NSMutableDictionary* object = [NSMutableDictionary dictionary];
      for (const auto& member : json.object) {
        object[stringOf(member.first)] = foundationOf(member.second);
      }
      return object;
    }
  }
  return [NSNull null];
}

}  // namespace

// #############################################################################
// The plugin's view of variant B: the view of a Flutter engine of its own
// inside the plugin's view.
class FlutterEditorView : public CPluginView, public ViewDelegate, public ParamObserver {
 public:
  // ...........................................................................
  // Creates the view of `plugin`, which it holds and observes.
  explicit FlutterEditorView(Plugin* plugin) : CPluginView(nullptr), plugin_(plugin) {
    ViewRect size(0, 0, static_cast<int32>(kEditorWidth),
                  static_cast<int32>(kEditorHeight));
    setRect(size);
    // The view holds the plugin, as the SDK's EditorView holds its
    // controller: a host may release the plugin before the view.
    plugin_->addRef();
    plugin_->addObserver(this);
  }

  // ...........................................................................
  // Tears the view down and lets the plugin go.
  ~FlutterEditorView() override {
    plugin_->removeObserver(this);
    teardown();
    plugin_->release();
  }

  // ###########################################################################
  // IPlugView

  tresult PLUGIN_API isPlatformTypeSupported(FIDString type) SMTG_OVERRIDE {
    return std::strcmp(type, kPlatformTypeNSView) == 0 ? kResultTrue
                                                        : kResultFalse;
  }

  tresult PLUGIN_API attached(void* parent, FIDString type) SMTG_OVERRIDE {
    if (isPlatformTypeSupported(type) != kResultTrue) return kResultFalse;
    attachStamp_ = nowNs();
    firstFrame_ = true;
    if (!loadFlutter(plugin_->probe())) return kResultFalse;
    NSView* parentView = (__bridge NSView*)parent;
    view_ = makeView(this, NSMakeRect(0, 0, rect.getWidth(), rect.getHeight()));
    [parentView addSubview:view_];

    NSBundle* app = [NSBundle
        bundleWithPath:[NSString stringWithFormat:@"%s/Contents/Frameworks/App.framework",
                                                  bundlePath().c_str()]];
    id<AudFlutterProject> project =
        [(id<AudFlutterProject>)[flutterClass("DartProject") alloc]
            initWithPrecompiledDartBundle:app];
    [project setDartEntrypointArguments:@[
      @"--inprocess", @"--instance", [NSString stringWithFormat:@"%u", plugin_->instance()]
    ]];
    engine_ = [(id<AudFlutterEngine>)[flutterClass("Engine") alloc]
                   initWithName:@"aud_vst3"
                        project:project
         allowHeadlessExecution:NO];
    [engine_ runWithEntrypoint:nil];
    controller_ = [(NSViewController<AudFlutterViewController>*)[flutterClass(
        "ViewController") alloc] initWithEngine:engine_ nibName:nil bundle:nil];
    NSView* flutterView = controller_.view;
    flutterView.frame = view_.bounds;
    flutterView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [view_ addSubview:flutterView];

    FlutterEditorView* self = this;
    channel_ = [(Class<AudFlutterMethodChannel>)flutterClass("MethodChannel")
        methodChannelWithName:@"aud_vst3/plugin"
              binaryMessenger:[engine_ binaryMessenger]];
    [channel_ setMethodCallHandler:^(id<AudFlutterMethodCall> call, void (^result)(id)) {
      self->handle(call.method, call.arguments);
      result(nil);
    }];
    meterTimer_ = [NSTimer timerWithTimeInterval:kMeterPeriod
                                         repeats:YES
                                           block:^(NSTimer*) {
                                             self->sendMeter();
                                           }];
    [[NSRunLoop mainRunLoop] addTimer:meterTimer_ forMode:NSRunLoopCommonModes];
    observeFrames();
    plugin_->probe().write(
        "attached", std::string("\"variant\":\"B\",\"class\":\"") +
                        viewClassName() + "\",\"implFlavor\":" +
                        std::to_string(implementationFlavor(view_)) +
                        ",\"engineClass\":\"" + class_getName(flutterClass("Engine")) +
                        "\"");
    return CPluginView::attached(parent, type);
  }

  tresult PLUGIN_API removed() SMTG_OVERRIDE {
    const int64_t start = nowNs();
    teardown();
    plugin_->probe().write("removed", "\"ns\":" + std::to_string(nowNs() - start));
    return CPluginView::removed();
  }

  tresult PLUGIN_API onSize(ViewRect* newSize) SMTG_OVERRIDE {
    if (newSize != nullptr && view_ != nil) {
      [view_ setFrame:NSMakeRect(0, 0, newSize->getWidth(), newSize->getHeight())];
    }
    return CPluginView::onSize(newSize);
  }

  tresult PLUGIN_API canResize() SMTG_OVERRIDE { return kResultTrue; }

  tresult PLUGIN_API checkSizeConstraint(ViewRect* r) SMTG_OVERRIDE {
    if (r == nullptr) return kInvalidArgument;
    if (r->getWidth() < kEditorMinWidth) {
      r->right = r->left + static_cast<int32>(kEditorMinWidth);
    }
    if (r->getHeight() < kEditorMinHeight) {
      r->bottom = r->top + static_cast<int32>(kEditorMinHeight);
    }
    return kResultTrue;
  }

  // ###########################################################################
  // ViewDelegate: only the synthetic drag arrives here; real input goes to
  // the Flutter view, which lies on top.

  void mouseEvent(NSView*, NSEvent* event) override {
    if (controller_ == nil) return;
    switch (event.type) {
      case NSEventTypeLeftMouseDown:
        [controller_ mouseDown:event];
        break;
      case NSEventTypeLeftMouseDragged:
        [controller_ mouseDragged:event];
        break;
      case NSEventTypeLeftMouseUp:
        [controller_ mouseUp:event];
        break;
      default:
        break;
    }
  }

  void keyEvent(NSView*, NSEvent* event) override {
    if (event.type == NSEventTypeKeyDown &&
        [event.charactersIgnoringModifiers isEqualToString:@"t"]) {
      testRequested();
    }
  }

  // ###########################################################################
  // ParamObserver

  void paramChanged(uint32_t id, double normalized) override {
    if (channel_ == nil || !ready_) return;
    const ParamMapping* m = plugin_->mapping(id);
    if (m == nullptr) return;
    const uint64_t sequence = ++paramSequence_;
    [channel_ invokeMethod:@"param"
                 arguments:@{
                   @"id" : @(id),
                   @"value" : boxed(m->toPlain(normalized)),
                   @"seq" : @(sequence)
                 }];
    plugin_->probe().write("paramSent", "\"id\":" + std::to_string(id) +
                                            ",\"value\":" + probeNumber(normalized) +
                                            ",\"seq\":" + std::to_string(sequence));
  }

  void testRequested() override {
    if (view_ == nil || drag_.running() || !ready_) return;
    const uint32_t id =
        aud_host_param_id(kKnobs[kTestKnob].nodeId, kKnobs[kTestKnob].paramId);
    plugin_->probe().write("testStart", "\"variant\":\"B\",\"id\":" + std::to_string(id));
    FlutterEditorView* self = this;
    drag_.start(
        view_, this,
        [self, id] {
          self->plugin_->editBegin(id, self);
          self->plugin_->edit(id, kTestStartValue, nowNs(), nullptr);
          self->plugin_->editEnd(id, self);
        },
        [self] { self->plugin_->probe().write("testEnd", "\"variant\":\"B\""); });
  }

  // ###########################################################################
  // FUnknown

  OBJ_METHODS(FlutterEditorView, CPluginView)
  REFCOUNT_METHODS(CPluginView)

 private:
  void handle(NSString* method, id arguments) {
    if ([method isEqualToString:@"ready"]) {
      ready_ = true;
      sendWelcome();
      return;
    }
    NSDictionary* args = [arguments isKindOfClass:[NSDictionary class]] ? arguments : nil;
    if ([method isEqualToString:@"command"] || [method isEqualToString:@"gesture"]) {
      const int32_t node = [args[@"node"] intValue];
      const uint32_t index = [args[@"paramIndex"] unsignedIntValue];
      const EngineParam* param = plugin_->param(node, index);
      if (param == nullptr) return;
      if ([method isEqualToString:@"gesture"]) {
        if ([args[@"phase"] isEqualToString:@"begin"]) plugin_->editBegin(param->id, this);
        if ([args[@"phase"] isEqualToString:@"end"]) plugin_->editEnd(param->id, this);
        return;
      }
      const ParamMapping* m = plugin_->mapping(param->id);
      if (m == nullptr) return;
      plugin_->edit(param->id, m->toNormalized([args[@"value"] floatValue]),
                    [args[@"input"] longLongValue], this);
      return;
    }
    if ([method isEqualToString:@"probe"]) {
      // The fields as JSON, as the socket path writes them.
      NSString* kind = args[@"kind"];
      NSDictionary* fields = args[@"fields"];
      if (![kind isKindOfClass:[NSString class]] ||
          kind.UTF8String == nullptr || !isProbeKind(kind.UTF8String) ||
          ![fields isKindOfClass:[NSDictionary class]] ||
          ![NSJSONSerialization isValidJSONObject:fields]) {
        return;
      }
      NSData* data = [NSJSONSerialization dataWithJSONObject:fields options:0 error:nil];
      std::string text(static_cast<const char*>(data.bytes), data.length);
      if (text.size() >= 2) text = text.substr(1, text.size() - 2);
      plugin_->probe().write(kind.UTF8String, text);
    }
  }

  void sendWelcome() {
    NSArray* params = foundationOf(welcomeParams(*plugin_));
    [channel_ invokeMethod:@"welcome" arguments:@{@"params" : params}];
  }

  void sendMeter() {
    Engine* engine = plugin_->engine();
    if (channel_ == nil || !ready_ || engine == nullptr) return;
    const EngineMeter meter = engine->meter();
    if (meter.peak == lastPeak_) return;
    lastPeak_ = meter.peak;
    [channel_ invokeMethod:@"meter"
                 arguments:@{@"peak" : boxed(meter.peak), @"rms" : boxed(meter.rms)}];
  }

  // Logs every frame Flutter commits into its view's layer, like the
  // frames of variant A.
  void observeFrames() {
    FlutterEditorView* self = this;
    frameTimer_ = [NSTimer timerWithTimeInterval:1.0 / 240
                                         repeats:YES
                                           block:^(NSTimer*) {
                                             self->checkFrame();
                                           }];
    [[NSRunLoop mainRunLoop] addTimer:frameTimer_ forMode:NSRunLoopCommonModes];
  }

  // Searches from the FlutterView, which is layer-backed in any host: a
  // host whose windows are not (REAPER) leaves the container without a
  // layer. Polling stamps a frame up to 4 ms after its commit.
  void checkFrame() {
    NSMutableArray<CALayer*>* stack = [NSMutableArray array];
    CALayer* root = controller_.view.layer;
    if (root != nil) [stack addObject:root];
    while (stack.count > 0) {
      CALayer* layer = stack.lastObject;
      [stack removeLastObject];
      id contents = layer.contents;
      if (contents != nil &&
          CFGetTypeID((__bridge CFTypeRef)contents) == IOSurfaceGetTypeID()) {
        const uint32_t seed = IOSurfaceGetSeed((__bridge IOSurfaceRef)contents);
        const void* surface = (__bridge const void*)contents;
        if (surface == lastSurface_ && seed == lastSeed_) return;
        lastSurface_ = surface;
        lastSeed_ = seed;
        const int64_t now = nowNs();
        plugin_->probe().write("presented",
                               "\"frame\":" + std::to_string(++frames_) +
                                   ",\"captured\":" + std::to_string(now));
        if (firstFrame_) {
          firstFrame_ = false;
          plugin_->probe().write("firstFrame", "\"variant\":\"B\",\"ns\":" +
                                                   std::to_string(now - attachStamp_));
        }
        return;
      }
      [stack addObjectsFromArray:layer.sublayers ?: @[]];
    }
  }

  void teardown() {
    drag_.stop();
    // A view closed mid-drag leaves no gesture open in the host.
    plugin_->endEdits(this);
    [meterTimer_ invalidate];
    meterTimer_ = nil;
    [frameTimer_ invalidate];
    frameTimer_ = nil;
    ready_ = false;
    if (channel_ != nil) {
      [channel_ setMethodCallHandler:nil];
      channel_ = nil;
    }
    [controller_.view removeFromSuperview];
    if (engine_ != nil) {
      // Flutter's ResizeSynchronizer runs a present it scheduled for a
      // later vsync even after the view is gone, and the present reaches
      // the engine's compositor: releasing the controller and shutting the
      // engine down at once crashed REAPER. Both live on until such
      // presents have run, the controller released first, as before.
      id<AudFlutterEngine> engine = engine_;
      __block NSViewController* controller = controller_;
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW, kEngineShutdownDelayNs),
                     dispatch_get_main_queue(), ^{
                       controller = nil;
                       [engine shutDownEngine];
                     });
    }
    controller_ = nil;
    engine_ = nil;
    if (view_ != nil) {
      clearDelegate(view_);
      [view_ removeFromSuperview];
      view_ = nil;
    }
  }

  Plugin* plugin_;
  NSView* view_ = nil;
  id<AudFlutterEngine> engine_ = nil;
  NSViewController* controller_ = nil;
  id<AudFlutterMethodChannel> channel_ = nil;
  NSTimer* meterTimer_ = nil;
  NSTimer* frameTimer_ = nil;
  const void* lastSurface_ = nullptr;
  uint32_t lastSeed_ = 0;
  uint64_t frames_ = 0;
  uint64_t paramSequence_ = 0;
  int64_t attachStamp_ = 0;
  bool firstFrame_ = false;
  bool ready_ = false;
  float lastPeak_ = -1;
  SyntheticDrag drag_;
};

// #############################################################################
IPlugView* createEditorView(Plugin* plugin) { return new FlutterEditorView(plugin); }

}  // namespace aud_vst3
