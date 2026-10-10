// @license
// Copyright (c) Audanika. All Rights Reserved.
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

// Variants A, S and F of the spike (ticket 24): the editor is a Flutter app
// in a process of its own.
//
// - A: one editor process per plugin instance (decision 5 of the plan
//   review), shown through shared IOSurfaces.
// - S: one editor process for every instance of this plugin build in the
//   DAW process, one Flutter view per open editor - the process model the
//   memory of A calls for.
// - F: like A, but the editor's own window follows the plugin's view, above
//   the host's window (A's comparison).
//
// The shell protocol runs over a Unix domain socket (SocketServer): the
// editor introduces itself with the token it was started with, the plugin
// sends every instance's parameters; edits come back as AudCommands,
// gestures as shell messages; host automation, meters and - in A and S -
// the input of the plugin's view go to the editor. Every message names its
// plugin instance. In A and S the editor copies every frame of each hidden
// FlutterView into IOSurfaces it shares over Mach (SurfaceChannel), and the
// plugin's view shows them as layer contents.
//
// The editor stays warm for a while after its last view closes (open
// question 2); a crashed or hung editor is restarted while a view is open,
// at most every 2 s and five times in a row without a hello. Gestures a
// closed view or a lost editor left open are ended in the host. Nothing
// here waits for the editor process: the socket's outbox is bounded, Mach
// sends time out at once. The editor quits when the socket ends or the DAW
// process exits.

#import <Cocoa/Cocoa.h>
#import <QuartzCore/QuartzCore.h>
#include <dlfcn.h>
#include <fcntl.h>
#include <signal.h>
#include <spawn.h>
#include <sys/wait.h>
#include <unistd.h>

#include <algorithm>
#include <cstdlib>
#include <map>
#include <memory>
#include <string>
#include <utility>
#include <vector>

#include "aud_json.hpp"
#include "aud_vst3_driver.hpp"
#include "aud_vst3_layout.hpp"
#include "aud_vst3_objc.hpp"
#include "aud_vst3_plugin.hpp"
#include "aud_vst3_socket.hpp"
#include "aud_vst3_surfaces.hpp"
#include "public.sdk/source/common/pluginview.h"

extern char** environ;

namespace aud_vst3 {

using namespace Steinberg;

namespace {

constexpr bool kFollow = AUD_VST3_VARIANT == 'F';
constexpr bool kShared = AUD_VST3_VARIANT == 'S';

// How long an editor whose last view closed stays warm;
// AUD_VST3_WARM_SECONDS overrides it, 0 closes at once.
double warmSeconds() {
  const char* value = std::getenv("AUD_VST3_WARM_SECONDS");
  return value != nullptr ? std::atof(value) : 10.0;
}

std::string bundlePath() {
  Dl_info info{};
  if (dladdr(reinterpret_cast<const void*>(&bundlePath), &info) == 0 ||
      info.dli_fname == nullptr) {
    return {};
  }
  // <bundle>.vst3/Contents/MacOS/<binary>
  std::string path = info.dli_fname;
  for (int i = 0; i < 3; ++i) path = path.substr(0, path.rfind('/'));
  return path;
}

std::string logDirectory() {
  const char* home = std::getenv("HOME");
  return std::string(home != nullptr ? home : "/tmp") +
         "/Library/Logs/aud_audio_vst3";
}

std::string tempDirectory() {
  const char* tmp = std::getenv("TMPDIR");
  std::string dir = tmp != nullptr ? tmp : "/tmp";
  while (dir.size() > 1 && dir.back() == '/') dir.pop_back();
  return dir;
}

std::string randomToken() {
  char token[33];
  std::snprintf(token, sizeof(token), "%08x%08x%08x%08x", arc4random(),
                arc4random(), arc4random(), arc4random());
  return token;
}

int64_t stampOf(NSEvent* event) {
  return static_cast<int64_t>(event.timestamp * 1e9);
}

aud::Json number(double value) { return aud::Json::ofNumber(value); }

aud::Json message(const char* type) {
  aud::Json json = aud::Json::ofObject();
  json.set("type", aud::Json::ofString(type));
  return json;
}

// The fields of a probe message as the inside of a JSON object.
std::string probeFields(const aud::Json& fields) {
  std::string text;
  aud::writeJson(fields, 0, &text);
  if (text.size() >= 2) text = text.substr(1, text.size() - 2);
  return text;
}

NSCursor* cursorOf(const std::string& kind) {
  if (kind == "resizeUpDown" || kind == "resizeUp" || kind == "resizeDown") {
    return [NSCursor resizeUpDownCursor];
  }
  if (kind == "resizeLeftRight") return [NSCursor resizeLeftRightCursor];
  if (kind == "click") return [NSCursor pointingHandCursor];
  if (kind == "text") return [NSCursor IBeamCursor];
  if (kind == "grab") return [NSCursor openHandCursor];
  if (kind == "grabbing") return [NSCursor closedHandCursor];
  return [NSCursor arrowCursor];
}

}  // namespace

class RemoteView;

// The editor process and its two channels; all of it runs on the host's UI
// thread except the channels' own threads. A and F give every plugin
// instance a host of its own, S shares one among the instances of this
// plugin build.
class EditorHost : public std::enable_shared_from_this<EditorHost> {
 public:
  static std::shared_ptr<EditorHost> forPlugin() {
    if (!kShared) return std::make_shared<EditorHost>();
    // Hidden symbols make this one per plugin build, never shared with
    // another aud_audio-based plugin.
    static std::weak_ptr<EditorHost> shared;
    auto host = shared.lock();
    if (host == nullptr) {
      host = std::make_shared<EditorHost>();
      shared = host;
    }
    return host;
  }

  ~EditorHost() {
    stopMeters();
    stopProcess();
  }

  void attach(Plugin* plugin, RemoteView* view);
  void detach(Plugin* plugin, RemoteView* view);

  // The plugin instance is gone.
  void remove(Plugin* plugin) {
    const auto it = clients_.find(plugin->instance());
    if (it == clients_.end()) return;
    clients_.erase(it);
    sentPeaks_.erase(plugin->instance());
    if (surfaces_ != nullptr) surfaces_->drop(plugin->instance());
    send(plugin->instance(), message("remove"));
  }

  void send(uint32_t instance, aud::Json json, bool droppable = false) {
    if (server_ == nullptr || !ready_) return;
    json.set("instance", number(instance));
    server_->send(json, droppable);
  }

  void releaseSurface(uint32_t instance, uint32_t index, uint32_t generation) {
    if (surfaces_ != nullptr) surfaces_->release(instance, index, generation);
  }

  uint64_t nextParamSequence() { return ++paramSequence_; }

  bool ready() const { return ready_; }

 private:
  struct Client {
    Plugin* plugin = nullptr;
    RemoteView* view = nullptr;
  };

  bool anyView() const {
    for (const auto& entry : clients_) {
      if (entry.second.view != nullptr) return true;
    }
    return false;
  }

  Probe* probe() {
    return clients_.empty() ? nullptr : &clients_.begin()->second.plugin->probe();
  }

  void ensureProcess(Plugin* plugin);
  bool spawn(Plugin* plugin);
  void stopProcess();
  void open(uint32_t instance);
  void handle(const aud::Json& json, uint64_t connection);
  void connectionLost(uint64_t connection);
  void exited(pid_t pid, int status);
  void endGestures();
  void scheduleRestart();
  void killLater(pid_t pid);
  void startMeters();
  void stopMeters();
  void sendMeters();

  std::map<uint32_t, Client> clients_;
  std::unique_ptr<SocketServer> server_;
  std::unique_ptr<SurfaceChannel> surfaces_;
  std::string token_;
  pid_t pid_ = 0;
  // Whether the process pid_ still lives; its exit handler clears it.
  std::shared_ptr<bool> alive_;
  bool ready_ = false;
  // The connection that said hello with the token.
  uint64_t connection_ = 0;
  // Starts in a row that never said hello.
  int failedStarts_ = 0;
  // One meter timer for every view, so that the meters of all instances
  // reach a shared editor in the same frame.
  NSTimer* meterTimer_ = nil;
  std::map<uint32_t, float> sentPeaks_;
  int64_t spawnStamp_ = 0;
  uint64_t paramSequence_ = 0;
  uint64_t detachCount_ = 0;
  int64_t lastRestart_ = 0;
};

// What a plugin instance keeps: its host and its place in it.
class HostedEditor : public EditorState {
 public:
  HostedEditor(Plugin* plugin, std::shared_ptr<EditorHost> host)
      : plugin_(plugin), host_(std::move(host)) {}
  ~HostedEditor() override { host_->remove(plugin_); }

  const std::shared_ptr<EditorHost>& host() const { return host_; }

 private:
  Plugin* plugin_;
  std::shared_ptr<EditorHost> host_;
};

// The plugin's view of variants A, S and F.
class RemoteView : public CPluginView, public ViewDelegate, public ParamObserver {
 public:
  explicit RemoteView(Plugin* plugin) : CPluginView(nullptr), plugin_(plugin) {
    ViewRect size(0, 0, static_cast<int32>(kEditorWidth),
                  static_cast<int32>(kEditorHeight));
    setRect(size);
    // The view holds the plugin, as the SDK's EditorView holds its
    // controller: a host may release the plugin before the view.
    plugin_->addRef();
    plugin_->addObserver(this);
  }

  ~RemoteView() override {
    plugin_->removeObserver(this);
    teardown();
    plugin_->release();
  }

  tresult PLUGIN_API isPlatformTypeSupported(FIDString type) SMTG_OVERRIDE {
    return std::strcmp(type, kPlatformTypeNSView) == 0 ? kResultTrue
                                                        : kResultFalse;
  }

  tresult PLUGIN_API attached(void* parent, FIDString type) SMTG_OVERRIDE {
    if (isPlatformTypeSupported(type) != kResultTrue) return kResultFalse;
    attachStamp_ = nowNs();
    firstFrame_ = true;
    NSView* parentView = (__bridge NSView*)parent;
    view_ = makeView(this, NSMakeRect(0, 0, rect.getWidth(), rect.getHeight()));
    CALayer* root = [CALayer layer];
    CGColorRef background = CGColorCreateGenericRGB(0.11, 0.12, 0.14, 1);
    root.backgroundColor = background;
    CGColorRelease(background);
    view_.layer = root;
    view_.wantsLayer = YES;
    surfaceLayer_ = [CALayer layer];
    surfaceLayer_.anchorPoint = CGPointZero;
    surfaceLayer_.contentsGravity = kCAGravityTopLeft;
    surfaceLayer_.frame = root.bounds;
    surfaceLayer_.autoresizingMask = kCALayerWidthSizable | kCALayerHeightSizable;
    [root addSublayer:surfaceLayer_];
    [parentView addSubview:view_];
    observeWindow(parentView.window);
    auto& state = plugin_->editorState();
    auto hosted = std::dynamic_pointer_cast<HostedEditor>(state);
    if (hosted == nullptr) {
      hosted = std::make_shared<HostedEditor>(plugin_, EditorHost::forPlugin());
      state = hosted;
    }
    host_ = hosted->host();
    plugin_->probe().write(
        "attached", std::string("\"variant\":\"") + kVariant +
                        "\",\"class\":\"" + viewClassName() +
                        "\",\"implFlavor\":" +
                        std::to_string(implementationFlavor(view_)));
    host_->attach(plugin_, this);
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
      [view_ setFrame:NSMakeRect(0, 0, newSize->getWidth(),
                                 newSize->getHeight())];
      sendPlace();
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

  // The geometry of the view for the editor; remembers the visibility it
  // reports.
  aud::Json place() {
    aud::Json json = message("place");
    NSWindow* window = view_.window;
    NSRect onScreen = NSZeroRect;
    double scale = 2;
    int64_t windowNumber = 0;
    bool visible = false;
    if (window != nil) {
      onScreen = [window convertRectToScreen:[view_ convertRect:view_.bounds
                                                         toView:nil]];
      scale = window.backingScaleFactor;
      windowNumber = window.windowNumber;
      visible = window.isVisible && !window.isMiniaturized &&
                (window.occlusionState & NSWindowOcclusionStateVisible) != 0;
    }
    json.set("x", number(onScreen.origin.x));
    json.set("y", number(onScreen.origin.y));
    json.set("width", number(view_ != nil ? view_.bounds.size.width : kEditorWidth));
    json.set("height",
             number(view_ != nil ? view_.bounds.size.height : kEditorHeight));
    json.set("scale", number(scale));
    json.set("window", number(static_cast<double>(windowNumber)));
    json.set("visible", aud::Json::ofBool(visible));
    sentVisible_ = visible;
    plugin_->probe().write(
        "place",
        std::string("\"visible\":") + (visible ? "true" : "false") +
            ",\"windowVisible\":" + (window != nil && window.isVisible ? "true" : "false") +
            ",\"occlusion\":" +
            std::to_string(window != nil ? static_cast<unsigned long>(window.occlusionState)
                                         : 0) +
            ",\"window\":" + std::to_string(windowNumber) +
            ",\"x\":" + std::to_string(static_cast<int>(onScreen.origin.x)) +
            ",\"y\":" + std::to_string(static_cast<int>(onScreen.origin.y)));
    return json;
  }

  void sendPlace() {
    if (host_ != nullptr && view_ != nil) host_->send(plugin_->instance(), place());
  }

  // Whether the view can be seen: in a visible window that is not
  // miniaturized, not occluded and on the current Space.
  bool visible() const {
    NSWindow* window = view_.window;
    return window != nil && window.isVisible && !window.isMiniaturized &&
           (window.occlusionState & NSWindowOcclusionStateVisible) != 0;
  }

  Plugin* plugin() const { return plugin_; }

  // Sends the place again when the view became visible or hidden without a
  // window notification: the first place can report the view hidden (a
  // host orders its window in after attaching the view), and not every
  // later change reaches the view as a notification. The host's meter
  // timer asks.
  void checkVisible() {
    if (view_ != nil && visible() != sentVisible_) sendPlace();
  }

  // Shows a frame of the editor (A and S).
  void showFrame(const SurfaceFrame& frame) {
    if (view_ == nil) {
      host_->releaseSurface(frame.instance, frame.index, frame.generation);
      CFRelease(frame.surface);
      return;
    }
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    surfaceLayer_.contentsScale = frame.scale;
    surfaceLayer_.contents = (__bridge id)frame.surface;
    [CATransaction commit];
    CFRelease(frame.surface);
    if (shownGeneration_ == frame.generation && shownIndex_ >= 0 &&
        static_cast<uint32_t>(shownIndex_) != frame.index) {
      host_->releaseSurface(frame.instance, static_cast<uint32_t>(shownIndex_),
                            frame.generation);
    }
    shownIndex_ = static_cast<int>(frame.index);
    shownGeneration_ = frame.generation;
    plugin_->probe().write("presented",
                           "\"frame\":" + std::to_string(frame.frame) +
                               ",\"captured\":" + std::to_string(frame.captured));
    if (firstFrame_) {
      firstFrame_ = false;
      plugin_->probe().write("firstFrame",
                             std::string("\"variant\":\"") + kVariant +
                                 "\",\"ns\":" +
                                 std::to_string(nowNs() - attachStamp_));
    }
  }

  // The editor took the instance (F shows nothing of its own).
  void editorReady() {
    if (kFollow && firstFrame_) {
      firstFrame_ = false;
      plugin_->probe().write("firstFrame",
                             std::string("\"variant\":\"") + kVariant +
                                 "\",\"ns\":" +
                                 std::to_string(nowNs() - attachStamp_));
    }
  }

  void setCursor(const std::string& kind) {
    cursorKind_ = kind;
    [cursorOf(kind) set];
  }

  // ViewDelegate

  void mouseEvent(NSView* view, NSEvent* event) override {
    if (kFollow || host_ == nullptr) return;
    const char* kind = nullptr;
    int buttons = 0;
    switch (event.type) {
      case NSEventTypeLeftMouseDown:
        kind = "down";
        buttons = 1;
        break;
      case NSEventTypeRightMouseDown:
        kind = "down";
        buttons = 2;
        break;
      case NSEventTypeOtherMouseDown:
        kind = "down";
        buttons = 4;
        break;
      case NSEventTypeLeftMouseDragged:
        kind = "move";
        buttons = 1;
        break;
      case NSEventTypeRightMouseDragged:
        kind = "move";
        buttons = 2;
        break;
      case NSEventTypeOtherMouseDragged:
        kind = "move";
        buttons = 4;
        break;
      case NSEventTypeLeftMouseUp:
      case NSEventTypeRightMouseUp:
      case NSEventTypeOtherMouseUp:
        kind = "up";
        break;
      case NSEventTypeMouseMoved:
        kind = "hover";
        break;
      case NSEventTypeMouseEntered:
        kind = "enter";
        break;
      case NSEventTypeMouseExited:
        kind = "exit";
        [[NSCursor arrowCursor] set];
        break;
      default:
        return;
    }
    if (event.type == NSEventTypeLeftMouseDown) [view.window makeFirstResponder:view];
    const NSPoint p = [view convertPoint:event.locationInWindow fromView:nil];
    aud::Json json = input(kind, event);
    json.set("x", number(p.x));
    json.set("y", number(p.y));
    json.set("buttons", number(buttons));
    // Moves are droppable; a lost down or up would break a gesture.
    host_->send(plugin_->instance(), json,
                std::strcmp(kind, "move") == 0 || std::strcmp(kind, "hover") == 0);
  }

  void scrollEvent(NSView* view, NSEvent* event) override {
    if (kFollow || host_ == nullptr) return;
    const NSPoint p = [view convertPoint:event.locationInWindow fromView:nil];
    // As FlutterViewController converts a wheel event: 40 points per line,
    // and Shift's swapped axes swapped back.
    const double factor = event.hasPreciseScrollingDeltas ? 1 : 40;
    double dx = -event.scrollingDeltaX * factor;
    double dy = -event.scrollingDeltaY * factor;
    if (event.modifierFlags & NSEventModifierFlagShift) std::swap(dx, dy);
    aud::Json json = input("scroll", event);
    json.set("x", number(p.x));
    json.set("y", number(p.y));
    json.set("dx", number(dx));
    json.set("dy", number(dy));
    host_->send(plugin_->instance(), json, true);
  }

  void keyEvent(NSView*, NSEvent* event) override {
    if (event.type == NSEventTypeKeyDown &&
        [event.charactersIgnoringModifiers isEqualToString:@"t"]) {
      testRequested();
      return;
    }
    if (kFollow || host_ == nullptr || event.type == NSEventTypeFlagsChanged) {
      return;
    }
    aud::Json json =
        input(event.type == NSEventTypeKeyDown ? "keyDown" : "keyUp", event);
    json.set("keyCode", number(event.keyCode));
    json.set("characters", aud::Json::ofString(event.characters.UTF8String ?: ""));
    host_->send(plugin_->instance(), json);
  }

  void focusChanged(NSView*, bool focused) override {
    if (kFollow || host_ == nullptr) return;
    aud::Json json = message("input");
    json.set("kind", aud::Json::ofString("focus"));
    json.set("focused", aud::Json::ofBool(focused));
    json.set("t", number(static_cast<double>(nowNs())));
    host_->send(plugin_->instance(), json);
  }

  void windowChanged(NSView* view) override {
    observeWindow(view.window);
    sendPlace();
  }

  void cursorUpdate(NSView*, NSEvent*) override { [cursorOf(cursorKind_) set]; }

  // ParamObserver

  void paramChanged(uint32_t id, double normalized) override {
    if (host_ == nullptr || !host_->ready()) return;
    const ParamMapping* m = plugin_->mapping(id);
    if (m == nullptr) return;
    const uint64_t sequence = host_->nextParamSequence();
    aud::Json json = message("param");
    json.set("id", number(id));
    json.set("value", number(m->toPlain(normalized)));
    json.set("seq", number(static_cast<double>(sequence)));
    host_->send(plugin_->instance(), json);
    plugin_->probe().write("paramSent", "\"id\":" + std::to_string(id) +
                                            ",\"value\":" + probeNumber(normalized) +
                                            ",\"seq\":" + std::to_string(sequence));
  }

  void testRequested() override {
    if (view_ == nil || drag_.running() || kFollow) return;
    uint32_t id = 0;
    for (const EngineParam& param : plugin_->params()) {
      if (param.nodeId == kKnobs[kTestKnob].nodeId &&
          param.paramId == kKnobs[kTestKnob].paramId) {
        id = param.id;
      }
    }
    plugin_->probe().write("testStart", std::string("\"variant\":\"") +
                                            kVariant + "\",\"id\":" +
                                            std::to_string(id));
    RemoteView* self = this;
    drag_.start(
        view_, this,
        [self, id] {
          // The preset reaches the editor like host automation.
          self->plugin_->editBegin(id, self);
          self->plugin_->edit(id, kTestStartValue, nowNs(), nullptr);
          self->plugin_->editEnd(id, self);
        },
        [self] {
          self->plugin_->probe().write(
              "testEnd", std::string("\"variant\":\"") + kVariant + "\"");
        });
  }

  OBJ_METHODS(RemoteView, CPluginView)
  REFCOUNT_METHODS(CPluginView)

 private:
  aud::Json input(const char* kind, NSEvent* event) const {
    aud::Json json = message("input");
    json.set("kind", aud::Json::ofString(kind));
    json.set("modifiers", number(static_cast<double>(event.modifierFlags)));
    json.set("t", number(static_cast<double>(stampOf(event))));
    return json;
  }

  void observeWindow(NSWindow* window) {
    if (window == observedWindow_) return;
    removeWindowObservers();
    observedWindow_ = window;
    if (window == nil) return;
    RemoteView* self = this;
    for (NSNotificationName name : @[
           NSWindowDidMoveNotification, NSWindowDidResizeNotification,
           NSWindowDidChangeScreenNotification,
           NSWindowDidChangeBackingPropertiesNotification,
           NSWindowDidMiniaturizeNotification,
           NSWindowDidDeminiaturizeNotification,
           NSWindowDidChangeOcclusionStateNotification,
           NSWindowDidBecomeKeyNotification, NSWindowDidBecomeMainNotification,
           NSWindowDidExposeNotification
         ]) {
      id token = [[NSNotificationCenter defaultCenter]
          addObserverForName:name
                      object:window
                       queue:nil
                  usingBlock:^(NSNotification*) {
                    self->sendPlace();
                  }];
      [windowObservers_ addObject:token];
    }
  }

  void removeWindowObservers() {
    for (id token in windowObservers_) {
      [[NSNotificationCenter defaultCenter] removeObserver:token];
    }
    [windowObservers_ removeAllObjects];
    observedWindow_ = nil;
  }

  void teardown() {
    drag_.stop();
    // A view closed mid-drag leaves no gesture open in the host.
    plugin_->endEdits(this);
    removeWindowObservers();
    if (host_ != nullptr) {
      if (shownIndex_ >= 0) {
        host_->releaseSurface(plugin_->instance(),
                              static_cast<uint32_t>(shownIndex_), shownGeneration_);
      }
      host_->detach(plugin_, this);
      host_ = nullptr;
    }
    shownIndex_ = -1;
    if (view_ != nil) {
      clearDelegate(view_);
      [view_ removeFromSuperview];
      view_ = nil;
      surfaceLayer_ = nil;
    }
  }

  Plugin* plugin_;
  std::shared_ptr<EditorHost> host_;
  NSView* view_ = nil;
  CALayer* surfaceLayer_ = nil;
  NSWindow* __weak observedWindow_ = nil;
  NSMutableArray* windowObservers_ = [NSMutableArray array];
  std::string cursorKind_ = "basic";
  int shownIndex_ = -1;
  uint32_t shownGeneration_ = 0;
  int64_t attachStamp_ = 0;
  bool firstFrame_ = false;
  bool sentVisible_ = false;
  SyntheticDrag drag_;
};

// ............................................................................
// EditorHost

void EditorHost::attach(Plugin* plugin, RemoteView* view) {
  Client& client = clients_[plugin->instance()];
  client.plugin = plugin;
  client.view = view;
  ++detachCount_;
  failedStarts_ = 0;
  startMeters();
  if (pid_ <= 0) {
    ensureProcess(plugin);
    return;
  }
  if (ready_) open(plugin->instance());
}

void EditorHost::detach(Plugin* plugin, RemoteView* view) {
  const auto it = clients_.find(plugin->instance());
  if (it == clients_.end() || it->second.view != view) return;
  it->second.view = nullptr;
  if (!anyView()) stopMeters();
  if (!ready_) {
    if (!anyView()) stopProcess();
    return;
  }
  send(plugin->instance(), message("hide"));
  aud::Json place = view->place();
  place.set("visible", aud::Json::ofBool(false));
  send(plugin->instance(), place);
  if (anyView()) return;
  const double warm = warmSeconds();
  const uint64_t count = ++detachCount_;
  std::weak_ptr<EditorHost> weak = shared_from_this();
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                               static_cast<int64_t>(warm * 1e9)),
                 dispatch_get_main_queue(), ^{
                   auto self = weak.lock();
                   if (self != nullptr && !self->anyView() &&
                       self->detachCount_ == count) {
                     self->stopProcess();
                   }
                 });
}

// Sends the instance's parameters, which makes the editor show a view for
// it, then its place.
void EditorHost::open(uint32_t instance) {
  const auto it = clients_.find(instance);
  if (it == clients_.end() || it->second.view == nullptr) return;
  Plugin* plugin = it->second.plugin;
  aud::Json welcome = message("welcome");
  welcome.set("name", aud::Json::ofString("aud_audio_vst3 spike"));
  welcome.set("version", number(1));
  aud::Json params = aud::Json::ofArray();
  for (const EngineParam& p : plugin->params()) {
    const ParamMapping* m = plugin->mapping(p.id);
    if (m == nullptr) continue;
    aud::Json param = aud::Json::ofObject();
    param.set("id", number(p.id));
    param.set("nodeId", aud::Json::ofString(p.nodeId));
    param.set("paramId", aud::Json::ofString(p.paramId));
    param.set("node", number(p.node));
    param.set("index", number(p.index));
    param.set("name", aud::Json::ofString(p.name));
    param.set("unit", aud::Json::ofString(p.unit));
    param.set("min", number(p.min));
    param.set("max", number(p.max));
    param.set("default", number(p.defaultValue));
    param.set("value", number(m->toPlain(plugin->normalized(p.id))));
    param.set("logarithmic", aud::Json::ofBool(m->logarithmic));
    param.set("steps", number(m->steps));
    params.push(std::move(param));
  }
  welcome.set("params", std::move(params));
  const aud::Json place = it->second.view->place();
  for (const char* key : {"width", "height", "scale"}) {
    const aud::Json* value = place.find(key);
    welcome.set(key, number(value != nullptr ? value->number : 0));
  }
  send(instance, welcome);
  send(instance, place);
  send(instance, message("show"));
}

void EditorHost::startMeters() {
  if (meterTimer_ != nil) return;
  std::weak_ptr<EditorHost> weak = shared_from_this();
  meterTimer_ = [NSTimer timerWithTimeInterval:1.0 / 30
                                       repeats:YES
                                         block:^(NSTimer*) {
                                           if (auto self = weak.lock()) self->sendMeters();
                                         }];
  [[NSRunLoop mainRunLoop] addTimer:meterTimer_ forMode:NSRunLoopCommonModes];
}

void EditorHost::stopMeters() {
  [meterTimer_ invalidate];
  meterTimer_ = nil;
}

// The meters of every visible view, back to back, and only those that
// changed: a shared editor draws them in one frame, and a hidden or quiet
// view costs nothing. Each view also reports a change of its visibility.
void EditorHost::sendMeters() {
  if (!ready_) return;
  for (const auto& entry : clients_) {
    RemoteView* view = entry.second.view;
    if (view == nullptr) continue;
    view->checkVisible();
    if (!view->visible()) continue;
    Engine* engine = entry.second.plugin->engine();
    if (engine == nullptr) continue;
    const EngineMeter meter = engine->meter();
    const auto sent = sentPeaks_.find(entry.first);
    if (sent != sentPeaks_.end() && sent->second == meter.peak) continue;
    sentPeaks_[entry.first] = meter.peak;
    aud::Json json = message("meter");
    json.set("peak", number(meter.peak));
    json.set("rms", number(meter.rms));
    send(entry.first, json, true);
  }
}

void EditorHost::ensureProcess(Plugin* plugin) {
  if (pid_ > 0) return;
  std::weak_ptr<EditorHost> weak = shared_from_this();
  if (server_ == nullptr) {
    server_ = std::make_unique<SocketServer>(
        [weak](const aud::Json& json, uint64_t connection) {
          aud::Json copy = json;
          dispatch_async(dispatch_get_main_queue(), ^{
            if (auto self = weak.lock()) self->handle(copy, connection);
          });
        },
        [weak](bool connected, uint64_t connection) {
          if (connected) return;
          dispatch_async(dispatch_get_main_queue(), ^{
            if (auto self = weak.lock()) self->connectionLost(connection);
          });
        });
    if (!server_->start(tempDirectory())) {
      plugin->probe().write("error", "\"message\":\"socket\"");
      server_.reset();
      return;
    }
  }
  if (!kFollow && surfaces_ == nullptr) {
    surfaces_ = std::make_unique<SurfaceChannel>([weak](const SurfaceFrame& frame) {
      auto self = weak.lock();
      if (self == nullptr) {
        CFRelease(frame.surface);
        return;
      }
      const auto it = self->clients_.find(frame.instance);
      if (it == self->clients_.end() || it->second.view == nullptr) {
        self->releaseSurface(frame.instance, frame.index, frame.generation);
        CFRelease(frame.surface);
        return;
      }
      it->second.view->showFrame(frame);
    });
    if (!surfaces_->start()) {
      plugin->probe().write("error", "\"message\":\"bootstrap_check_in\"");
      surfaces_.reset();
      return;
    }
  }
  if (surfaces_ != nullptr) surfaces_->reset();
  spawn(plugin);
}

bool EditorHost::spawn(Plugin* plugin) {
  const std::string executable =
      bundlePath() +
      "/Contents/Helpers/aud_audio_vst3_editor.app/Contents/MacOS/"
      "aud_audio_vst3_editor";
  token_ = randomToken();
  std::vector<std::string> args = {
      executable,
      "--socket", server_->path(),
      "--token", token_,
      "--instance", std::to_string(plugin->instance()),
      "--mode", kFollow ? "follow" : "surface",
  };
  if (surfaces_ != nullptr) {
    args.push_back("--mach");
    args.push_back(surfaces_->name());
  }
  std::vector<char*> argv;
  for (std::string& arg : args) argv.push_back(arg.data());
  argv.push_back(nullptr);
  posix_spawn_file_actions_t actions;
  posix_spawn_file_actions_init(&actions);
  const std::string log =
      logDirectory() + "/editor-" + std::to_string(getpid()) + ".log";
  posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0);
  posix_spawn_file_actions_addopen(&actions, STDOUT_FILENO, log.c_str(),
                                   O_WRONLY | O_CREAT | O_APPEND, 0644);
  posix_spawn_file_actions_adddup2(&actions, STDOUT_FILENO, STDERR_FILENO);
  // The editor inherits stdin, stdout and stderr and nothing else of the
  // DAW: no sockets, pipes or files of other plugins.
  posix_spawnattr_t attributes;
  posix_spawnattr_init(&attributes);
  posix_spawnattr_setflags(&attributes, POSIX_SPAWN_CLOEXEC_DEFAULT);
  spawnStamp_ = nowNs();
  pid_t pid = 0;
  const int result = posix_spawn(&pid, executable.c_str(), &actions, &attributes,
                                 argv.data(), environ);
  posix_spawnattr_destroy(&attributes);
  posix_spawn_file_actions_destroy(&actions);
  if (result != 0) {
    plugin->probe().write("error", "\"message\":\"posix_spawn " +
                                       std::to_string(result) + "\"");
    return false;
  }
  pid_ = pid;
  alive_ = std::make_shared<bool>(true);
  plugin->probe().write("editorSpawn", "\"pid\":" + std::to_string(pid) +
                                           ",\"ns\":" +
                                           std::to_string(nowNs() - spawnStamp_));
  // Reaps the child whatever happens to this object.
  std::weak_ptr<EditorHost> weak = shared_from_this();
  std::shared_ptr<bool> alive = alive_;
  dispatch_source_t source = dispatch_source_create(
      DISPATCH_SOURCE_TYPE_PROC, static_cast<uintptr_t>(pid),
      DISPATCH_PROC_EXIT, dispatch_get_main_queue());
  dispatch_source_set_event_handler(source, ^{
    int status = 0;
    waitpid(pid, &status, 0);
    *alive = false;
    dispatch_source_cancel(source);
    if (auto self = weak.lock()) self->exited(pid, status);
  });
  dispatch_resume(source);
  // An editor that never says hello is killed and started again.
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 10'000'000'000),
                 dispatch_get_main_queue(), ^{
                   auto self = weak.lock();
                   if (self == nullptr || self->pid_ != pid || self->ready_ || !*alive) {
                     return;
                   }
                   if (Probe* p = self->probe()) {
                     p->write("error", "\"message\":\"no hello\"");
                   }
                   kill(pid, SIGKILL);
                 });
  return true;
}

// Kills `pid` in a second unless it exits on its own - an editor quits when
// its socket ends, a hung one does not. The block runs on the main queue,
// as the exit handler does, so it never hits a reaped pid.
void EditorHost::killLater(pid_t pid) {
  std::shared_ptr<bool> alive = alive_;
  if (pid <= 0 || alive == nullptr) return;
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1'000'000'000),
                 dispatch_get_main_queue(), ^{
                   if (*alive) kill(pid, SIGKILL);
                 });
}

void EditorHost::stopProcess() {
  endGestures();
  ready_ = false;
  connection_ = 0;
  token_.clear();
  if (pid_ > 0) {
    // The end of the socket makes the editor quit; a hung one is killed.
    killLater(pid_);
    pid_ = 0;
  }
  server_.reset();
  surfaces_.reset();
}

// Ends the gestures of every view in the host: their editor is gone.
void EditorHost::endGestures() {
  for (const auto& entry : clients_) {
    if (entry.second.view != nullptr) entry.second.plugin->endEdits(entry.second.view);
  }
}

// The editor's connection ended: it quit, crashed or was cut off because
// it read nothing (a hung editor). Its gestures end; a process that is
// still there is killed, and exited() starts a new one for the open views.
void EditorHost::connectionLost(uint64_t connection) {
  if (connection == 0 || connection != connection_) return;
  ready_ = false;
  connection_ = 0;
  endGestures();
  if (pid_ > 0) killLater(pid_);
}

// A new editor for the open views, at most every 2 s, and not after five
// starts in a row that never said hello.
void EditorHost::scheduleRestart() {
  if (failedStarts_ >= 5) {
    if (Probe* p = probe()) p->write("error", "\"message\":\"editor gave up\"");
    return;
  }
  const int64_t wait = std::max<int64_t>(0, lastRestart_ + 2'000'000'000 - nowNs());
  std::weak_ptr<EditorHost> weak = shared_from_this();
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, wait), dispatch_get_main_queue(), ^{
    auto self = weak.lock();
    if (self == nullptr || self->pid_ > 0) return;
    for (const auto& entry : self->clients_) {
      if (entry.second.view == nullptr) continue;
      self->lastRestart_ = nowNs();
      self->ensureProcess(entry.second.plugin);
      return;
    }
  });
}

void EditorHost::exited(pid_t pid, int status) {
  if (Probe* p = probe()) {
    p->write("editorExit", "\"pid\":" + std::to_string(pid) +
                               ",\"status\":" + std::to_string(status));
  }
  if (pid != pid_) return;
  pid_ = 0;
  if (!ready_) ++failedStarts_;
  ready_ = false;
  endGestures();
  if (server_ != nullptr && connection_ != 0) server_->disconnect(connection_);
  connection_ = 0;
  // A crashed editor of an open view comes back.
  if (anyView()) scheduleRestart();
}

void EditorHost::handle(const aud::Json& json, uint64_t connection) {
  const aud::Json* type = json.find("type");
  if (type == nullptr || !type->isString()) return;
  const std::string& kind = type->string;
  if (kind == "hello") {
    // A hello of a stopped editor, still queued, finds no server or token.
    if (server_ == nullptr || pid_ <= 0 || token_.empty()) return;
    const aud::Json* token = json.find("token");
    if (token == nullptr || token->string != token_) {
      if (Probe* p = probe()) p->write("error", "\"message\":\"bad token\"");
      server_->disconnect(connection);
      return;
    }
    server_->authenticate(connection);
    connection_ = connection;
    failedStarts_ = 0;
    ready_ = true;
    if (Probe* p = probe()) {
      p->write("editorHello", "\"ns\":" + std::to_string(nowNs() - spawnStamp_));
    }
    for (const auto& entry : clients_) {
      if (entry.second.view != nullptr) open(entry.first);
    }
    return;
  }
  if (!ready_ || connection != connection_) return;
  const aud::Json* instanceField = json.find("instance");
  if (instanceField == nullptr) return;
  const auto it = clients_.find(static_cast<uint32_t>(instanceField->number));
  if (it == clients_.end()) return;
  Plugin* plugin = it->second.plugin;
  RemoteView* view = it->second.view;
  if (kind == "command" || kind == "gesture") {
    const aud::Json* command = kind == "command" ? json.find("command") : &json;
    if (command == nullptr) return;
    const aud::Json* node = command->find("node");
    const aud::Json* index = command->find("paramIndex");
    if (node == nullptr || index == nullptr) return;
    const EngineParam* param = nullptr;
    for (const EngineParam& p : plugin->params()) {
      if (p.node == static_cast<int32_t>(node->number) &&
          p.index == static_cast<uint32_t>(index->number)) {
        param = &p;
      }
    }
    if (param == nullptr) return;
    // Edits belong to a view: those of a closed one were ended with it.
    if (view == nullptr) return;
    if (kind == "gesture") {
      const aud::Json* phase = json.find("phase");
      if (phase != nullptr && phase->string == "begin") plugin->editBegin(param->id, view);
      if (phase != nullptr && phase->string == "end") plugin->editEnd(param->id, view);
      return;
    }
    const aud::Json* name = command->find("command");
    const aud::Json* value = command->find("value");
    if (name == nullptr || name->string != "setParam" || value == nullptr) return;
    const ParamMapping* m = plugin->mapping(param->id);
    if (m == nullptr) return;
    const aud::Json* inputStamp = json.find("input");
    plugin->edit(param->id, m->toNormalized(static_cast<float>(value->number)),
                 inputStamp != nullptr ? static_cast<int64_t>(inputStamp->number) : 0,
                 view);
    return;
  }
  if (kind == "cursor") {
    const aud::Json* cursor = json.find("kind");
    if (view != nullptr && cursor != nullptr) view->setCursor(cursor->string);
    return;
  }
  if (kind == "probe") {
    const aud::Json* probeKind = json.find("kind");
    const aud::Json* fields = json.find("fields");
    if (probeKind != nullptr && fields != nullptr && fields->isObject()) {
      plugin->probe().write(probeKind->string.c_str(), probeFields(*fields));
      // F shows nothing of its own: its first frame is the editor's
      // window shown over the view.
      if (probeKind->string == "shown" && view != nullptr) view->editorReady();
    }
    return;
  }
}

IPlugView* createEditorView(Plugin* plugin) { return new RemoteView(plugin); }

}  // namespace aud_vst3
