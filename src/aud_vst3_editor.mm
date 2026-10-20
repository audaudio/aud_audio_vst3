// @license
// Copyright (c) Audanika. All Rights Reserved.
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

// The editor of the plugin (plugin-003, ticket 37): a Flutter app in a
// process of its own - the app plugin.json names as `editor`, inside the
// bundle's Contents/Helpers -, one process for every instance of this plugin
// build in the DAW process, one Flutter view per open editor (the spike's
// variant S, ticket 24).
//
// The editor runs in the App Sandbox when it ships in a Mac App Store app:
// it reaches no socket file of the DAW and looks up only Mach names with
// the prefix of its app group (plugin-007). So the plugin starts it with one
// end of a socket pair as its file descriptor 3 (SocketServer::connectPair)
// and registers the Mach port of the frames under a name with the app
// group's prefix (SurfaceChannel); no file is made anywhere.
//
// Over the socket the editor introduces itself with the token it was
// started with; the plugin sends every instance's welcome - its parameters,
// presets and the preset that plays -, the place of its view, its input
// and the changes of parameters and presets. The editor sends edits of
// parameters with their gestures, the MIDI its play surface plays, the
// preset it chose and its cursor. Every message names its plugin instance.
// The editor copies every frame of each hidden FlutterView into IOSurfaces
// it shares over Mach, and the plugin's view shows them as layer contents.
//
// The editor stays warm for 10 s after its last view closes; a crashed or
// hung editor is restarted while a view is open, at most every 2 s and five
// times in a row without a hello. Gestures a closed view or a lost editor
// left open are ended in the DAW. Nothing here waits for the editor
// process: the socket's outbox is bounded, Mach sends time out at once. The
// editor quits when the socket ends or the DAW process exits.

#import <Cocoa/Cocoa.h>
#import <QuartzCore/QuartzCore.h>
#include <fcntl.h>
#include <signal.h>
#include <spawn.h>
#include <sys/wait.h>
#include <unistd.h>

#include <algorithm>
#include <cstdlib>
#include <limits>
#include <map>
#include <memory>
#include <optional>
#include <string>
#include <utility>
#include <vector>

#include "aud_clock.h"
#include "aud_json.hpp"
#include "public.sdk/source/common/pluginview.h"

#include "aud_vst3_bundle.hpp"
#include "aud_vst3_objc.hpp"
#include "aud_vst3_plugin.hpp"
#include "aud_vst3_socket.hpp"
#include "aud_vst3_surfaces.hpp"

extern char** environ;

namespace aud_vst3 {

using namespace Steinberg;

namespace {

// The version of the shell protocol (audShellProtocolVersion).
constexpr int kProtocolVersion = 2;

// The prefix of the frames' Mach name for an editor without app group.
constexpr const char* kDefaultMachPrefix = "io.audaudio";

// How long a started editor may take to say hello before it is killed and
// started again.
constexpr int64_t kHelloTimeoutNs = 10'000'000'000;

// How long an editor whose socket ended may take to quit before it is
// killed.
constexpr int64_t kKillGraceNs = 1'000'000'000;

// The starts in a row without a hello after which no editor is started.
constexpr int kMaxFailedStarts = 5;

// The shortest time from one start of a crashed editor to the next.
constexpr int64_t kRestartIntervalNs = 2'000'000'000;

// How long an editor whose last view closed stays warm.
constexpr double kWarmSeconds = 10;

// How often the views check whether they can be seen: not every change
// reaches a view as a window notification.
constexpr double kVisibilityPeriod = 0.1;

// The most MIDI bytes one message of the editor may carry.
constexpr size_t kMaxMidiBytes = 4096;

// The background of the view until the editor's first frame.
constexpr double kBackground[3] = {0.11, 0.12, 0.14};

// A frame that took longer from the editor to the view - the DAW's main
// thread did not run the plugin's work - is logged, at most once a second.
constexpr int64_t kLateFrameNs = 250'000'000;

int64_t nowNs() { return aud_clock_now_ns(); }

std::string randomToken() {
  char token[33];
  std::snprintf(token, sizeof(token), "%08x%08x%08x%08x", arc4random(),
                arc4random(), arc4random(), arc4random());
  return token;
}

aud::Json number(double value) { return aud::Json::ofNumber(value); }

// The member `key` of `json` if it is an integer from `min` to `max`. The
// editor is another process: none of its numbers is cast unchecked.
std::optional<int64_t> integerIn(const aud::Json& json, const char* key,
                                 int64_t min, int64_t max) {
  const aud::Json* value = json.find(key);
  if (value == nullptr || !value->isInteger()) return std::nullopt;
  const int64_t integer = value->integer();
  if (integer < min || integer > max) return std::nullopt;
  return integer;
}

aud::Json message(const char* type) {
  aud::Json json = aud::Json::ofObject();
  json.set("type", aud::Json::ofString(type));
  return json;
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

// The executable of the editor app `name` in the plugin's Contents/Helpers.
std::string editorExecutable(const std::string& name) {
  @autoreleasepool {
    const std::string app = resolvedBundlePath() + "/Contents/Helpers/" + name;
    NSBundle* bundle =
        [NSBundle bundleWithPath:[NSString stringWithUTF8String:app.c_str()]];
    NSString* executable = bundle.executablePath;
    return executable != nil ? std::string(executable.UTF8String) : std::string();
  }
}

// The parameters the DAW sees, as the welcome lists them: one AudShellParam
// with the current value each.
aud::Json welcomeParams(Plugin& plugin) {
  aud::Json params = aud::Json::ofArray();
  Engine* engine = plugin.engine();
  if (engine == nullptr) return params;
  for (const ShellParam& shellParam : plugin.settings().params) {
    const EngineParam* p = engine->param(shellParam.id);
    const ParamMapping* m = plugin.mapping(shellParam.id);
    if (p == nullptr || m == nullptr) continue;
    aud::Json param = aud::Json::ofObject();
    param.set("id", number(p->id));
    param.set("nodeId", aud::Json::ofString(p->nodeId));
    param.set("paramId", aud::Json::ofString(p->paramId));
    param.set("node", number(p->node));
    param.set("index", number(p->index));
    param.set("name", aud::Json::ofString(shellParam.name));
    param.set("unit", aud::Json::ofString(p->unit));
    param.set("min", number(p->min));
    param.set("max", number(p->max));
    param.set("default", number(p->defaultValue));
    param.set("value", number(m->toPlain(plugin.normalized(p->id))));
    param.set("logarithmic", aud::Json::ofBool(m->logarithmic));
    param.set("steps", number(m->steps));
    params.push(std::move(param));
  }
  return params;
}

aud::Json welcomePresets(const Plugin& plugin) {
  aud::Json presets = aud::Json::ofArray();
  for (const ShellPreset& preset : plugin.settings().presets) {
    aud::Json entry = aud::Json::ofObject();
    entry.set("id", aud::Json::ofString(preset.id));
    entry.set("name", aud::Json::ofString(preset.name));
    presets.push(std::move(entry));
  }
  return presets;
}

}  // namespace

class EditorView;

// #############################################################################
// The editor process and its two channels; all of it runs on the DAW's UI
// thread except the channels' own threads. Every instance of this plugin
// build shares one.
class EditorHost : public std::enable_shared_from_this<EditorHost> {
 public:
  // ...........................................................................
  // The host every instance of this plugin build shares; hidden symbols make
  // it one per build, never shared with another plugin over the engine.
  static std::shared_ptr<EditorHost> shared() {
    static std::weak_ptr<EditorHost> shared;
    auto host = shared.lock();
    if (host == nullptr) {
      host = std::make_shared<EditorHost>();
      shared = host;
    }
    return host;
  }

  // ...........................................................................
  // Stops the visibility checks and the editor process.
  ~EditorHost() {
    stopTimer();
    stopProcess();
  }

  // ...........................................................................
  // Adds `view` of `plugin` and shows it in the editor, which it starts
  // when none runs.
  void attach(Plugin* plugin, EditorView* view);

  // ...........................................................................
  // Takes `view` of `plugin` away: the editor hides it, and quits after
  // kWarmSeconds without a view.
  void detach(Plugin* plugin, EditorView* view);

  // ...........................................................................
  // The plugin instance is gone.
  void remove(Plugin* plugin) {
    const auto it = clients_.find(plugin->instance());
    if (it == clients_.end()) return;
    clients_.erase(it);
    if (surfaces_ != nullptr) surfaces_->drop(plugin->instance());
    send(plugin->instance(), message("remove"));
  }

  // ...........................................................................
  // Sends `json` as a message of plugin instance `instance` once the
  // editor said hello; SocketServer::send() tells what `droppable` means.
  void send(uint32_t instance, aud::Json json, bool droppable = false) {
    if (server_ == nullptr || !ready_) return;
    json.set("instance", number(instance));
    server_->send(json, droppable);
  }

  // ...........................................................................
  // Hands surface `index` of `instance` back to the editor.
  void releaseSurface(uint32_t instance, uint32_t index, uint32_t generation) {
    if (surfaces_ != nullptr) surfaces_->release(instance, index, generation);
  }

  // ...........................................................................
  // Whether the editor said hello and takes messages.
  bool ready() const { return ready_; }

 private:
  struct Client {
    Plugin* plugin = nullptr;
    EditorView* view = nullptr;
  };

  bool anyView() const {
    for (const auto& entry : clients_) {
      if (entry.second.view != nullptr) return true;
    }
    return false;
  }

  void ensureProcess(Plugin* plugin);
  bool spawn(Plugin* plugin);
  void stopProcess();
  void open(uint32_t instance);
  void handle(const aud::Json& json, uint64_t connection);
  void connectionLost(uint64_t connection);
  void exited(pid_t pid, int status);
  // Ends the notes the editor holds in every instance: its note offs never
  // come.
  void releaseNotes();
  void endGestures();
  void scheduleRestart();
  void killLater(pid_t pid);
  void startTimer();
  void stopTimer();
  void checkVisibility();

  std::map<uint32_t, Client> clients_;
  std::unique_ptr<SocketServer> server_;
  std::unique_ptr<SurfaceChannel> surfaces_;
  std::string token_;
  pid_t pid_ = 0;
  // Whether the process pid_ still lives; its exit handler clears it.
  std::shared_ptr<bool> alive_;
  bool ready_ = false;
  // The connection of the editor's socket pair.
  uint64_t connection_ = 0;
  // Starts in a row that never said hello.
  int failedStarts_ = 0;
  NSTimer* timer_ = nil;
  uint64_t detachCount_ = 0;
  int64_t lastRestart_ = 0;
};

// #############################################################################
// What a plugin instance keeps: its host.
class HostedEditor : public EditorState {
 public:
  // ...........................................................................
  // Keeps `host` for `plugin`.
  HostedEditor(Plugin* plugin, std::shared_ptr<EditorHost> host)
      : plugin_(plugin), host_(std::move(host)) {}

  // ...........................................................................
  // Takes the plugin instance out of its host.
  ~HostedEditor() override { host_->remove(plugin_); }

  // ...........................................................................
  // The host of the plugin instance.
  const std::shared_ptr<EditorHost>& host() const { return host_; }

 private:
  Plugin* plugin_;
  std::shared_ptr<EditorHost> host_;
};

// #############################################################################
// The plugin's view: shows the editor's frames and forwards its input.
class EditorView : public CPluginView, public ViewDelegate, public PluginObserver {
 public:
  // ...........................................................................
  // Creates the view of `plugin`, which it holds and observes.
  explicit EditorView(Plugin* plugin) : CPluginView(nullptr), plugin_(plugin) {
    const Settings& settings = plugin_->settings();
    ViewRect size(0, 0, static_cast<int32>(settings.editorWidth),
                  static_cast<int32>(settings.editorHeight));
    setRect(size);
    // The view holds the plugin, as the SDK's EditorView holds its
    // controller: a DAW may release the plugin before the view.
    plugin_->addRef();
    plugin_->addObserver(this);
  }

  // ...........................................................................
  // Tears the view down and lets the plugin go.
  ~EditorView() override {
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
    NSView* parentView = (__bridge NSView*)parent;
    view_ = makeView(this, NSMakeRect(0, 0, rect.getWidth(), rect.getHeight()));
    CALayer* root = [CALayer layer];
    CGColorRef background = CGColorCreateGenericRGB(
        kBackground[0], kBackground[1], kBackground[2], 1);
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
      hosted = std::make_shared<HostedEditor>(plugin_, EditorHost::shared());
      state = hosted;
    }
    host_ = hosted->host();
    host_->attach(plugin_, this);
    return CPluginView::attached(parent, type);
  }

  tresult PLUGIN_API removed() SMTG_OVERRIDE {
    teardown();
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
    const Settings& settings = plugin_->settings();
    if (r->getWidth() < settings.editorMinWidth) {
      r->right = r->left + static_cast<int32>(settings.editorMinWidth);
    }
    if (r->getHeight() < settings.editorMinHeight) {
      r->bottom = r->top + static_cast<int32>(settings.editorMinHeight);
    }
    return kResultTrue;
  }

  // ###########################################################################
  // The editor host

  // ...........................................................................
  // The geometry of the view for the editor; remembers the visibility it
  // reports.
  aud::Json place() {
    aud::Json json = message("place");
    NSWindow* window = view_.window;
    NSRect onScreen = NSZeroRect;
    double scale = 2;
    int64_t windowNumber = 0;
    if (window != nil) {
      onScreen = [window convertRectToScreen:[view_ convertRect:view_.bounds
                                                         toView:nil]];
      scale = window.backingScaleFactor;
      windowNumber = window.windowNumber;
    }
    const bool seen = visible();
    const Settings& settings = plugin_->settings();
    json.set("x", number(onScreen.origin.x));
    json.set("y", number(onScreen.origin.y));
    json.set("width",
             number(view_ != nil ? view_.bounds.size.width : settings.editorWidth));
    json.set("height", number(view_ != nil ? view_.bounds.size.height
                                           : settings.editorHeight));
    json.set("scale", number(scale));
    json.set("window", number(static_cast<double>(windowNumber)));
    json.set("visible", aud::Json::ofBool(seen));
    if (seen != sentVisible_ || !placed_) logVisibility(seen);
    sentVisible_ = seen;
    placed_ = true;
    return json;
  }

  // ...........................................................................
  // Sends the place to the editor.
  void sendPlace() {
    if (host_ != nullptr && view_ != nil) host_->send(plugin_->instance(), place());
  }

  // ...........................................................................
  // Whether the view can be seen: in a visible window that is not
  // miniaturized, not occluded and on the current Space.
  bool visible() const {
    NSWindow* window = view_.window;
    return window != nil && window.isVisible && !window.isMiniaturized &&
           (window.occlusionState & NSWindowOcclusionStateVisible) != 0;
  }

  // ...........................................................................
  // Sends the place again when the view became visible or hidden without a
  // window notification: the first place can report the view hidden (a DAW
  // orders its window in after attaching the view).
  void checkVisible() {
    if (view_ != nil && visible() != sentVisible_) sendPlace();
  }

  // ...........................................................................
  // Shows a frame of the editor.
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
    logLateFrame(frame);
    if (shownGeneration_ == frame.generation && shownIndex_ >= 0 &&
        static_cast<uint32_t>(shownIndex_) != frame.index) {
      host_->releaseSurface(frame.instance, static_cast<uint32_t>(shownIndex_),
                            frame.generation);
    }
    shownIndex_ = static_cast<int>(frame.index);
    shownGeneration_ = frame.generation;
  }

  // ...........................................................................
  // Logs a frame that reached the view late.
  void logLateFrame(const SurfaceFrame& frame) {
    const int64_t now = nowNs();
    const int64_t waited = now - static_cast<int64_t>(frame.captured);
    if (waited < kLateFrameNs || waited > 60'000'000'000LL ||
        now - lastLateLog_ < 1'000'000'000) {
      return;
    }
    lastLateLog_ = now;
    logInfo("Instance " + std::to_string(plugin_->instance()) +
            ": a frame of the editor reached the view after " +
            std::to_string(waited / 1'000'000) + " ms");
  }

  // ...........................................................................
  // Logs a change of the view's visibility, which pauses or resumes the
  // editor, with what it rests on.
  void logVisibility(bool seen) const {
    NSWindow* window = view_.window;
    logInfo("Instance " + std::to_string(plugin_->instance()) + ": the view " +
            (seen ? "shows" : "hides") + " (window " +
            (window == nil ? "none"
                           : std::string(window.isVisible ? "visible" : "invisible") +
                                 (window.isMiniaturized ? ", miniaturized" : "") +
                                 ((window.occlusionState & NSWindowOcclusionStateVisible) != 0
                                      ? ", not occluded"
                                      : ", occluded")) +
            ")");
  }

  // ...........................................................................
  // Sets the cursor the editor asks for over the view.
  void setCursor(const std::string& kind) {
    cursorKind_ = kind;
    [cursorOf(kind) set];
  }

  // ###########################################################################
  // ViewDelegate

  void mouseEvent(NSView* view, NSEvent* event) override {
    if (host_ == nullptr) return;
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
    if (host_ == nullptr) return;
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
    if (host_ == nullptr || event.type == NSEventTypeFlagsChanged) return;
    aud::Json json =
        input(event.type == NSEventTypeKeyDown ? "keyDown" : "keyUp", event);
    json.set("keyCode", number(event.keyCode));
    json.set("characters", aud::Json::ofString(event.characters.UTF8String ?: ""));
    host_->send(plugin_->instance(), json);
  }

  void focusChanged(NSView*, bool focused) override {
    if (host_ == nullptr) return;
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

  // ###########################################################################
  // PluginObserver

  void paramChanged(uint32_t id, double normalized) override {
    if (host_ == nullptr || !host_->ready()) return;
    const ParamMapping* m = plugin_->mapping(id);
    if (m == nullptr) return;
    aud::Json json = message("param");
    json.set("id", number(id));
    json.set("value", number(m->toPlain(normalized)));
    host_->send(plugin_->instance(), json);
  }

  void presetChanged(uint32_t index) override {
    if (host_ == nullptr || !host_->ready()) return;
    aud::Json json = message("preset");
    json.set("index", number(index));
    host_->send(plugin_->instance(), json);
  }

  // ###########################################################################
  // FUnknown

  OBJ_METHODS(EditorView, CPluginView)
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
    EditorView* self = this;
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
    // A view closed mid-gesture leaves no gesture open in the DAW.
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
  bool sentVisible_ = false;
  bool placed_ = false;
  int64_t lastLateLog_ = 0;
};

// #############################################################################
// EditorHost

// .............................................................................
void EditorHost::attach(Plugin* plugin, EditorView* view) {
  Client& client = clients_[plugin->instance()];
  client.plugin = plugin;
  client.view = view;
  ++detachCount_;
  failedStarts_ = 0;
  startTimer();
  if (pid_ <= 0) {
    ensureProcess(plugin);
    return;
  }
  if (ready_) open(plugin->instance());
}

// .............................................................................
void EditorHost::detach(Plugin* plugin, EditorView* view) {
  const auto it = clients_.find(plugin->instance());
  if (it == clients_.end() || it->second.view != view) return;
  it->second.view = nullptr;
  if (!anyView()) stopTimer();
  if (!ready_) {
    if (!anyView()) stopProcess();
    return;
  }
  send(plugin->instance(), message("hide"));
  aud::Json place = view->place();
  place.set("visible", aud::Json::ofBool(false));
  send(plugin->instance(), place);
  if (anyView()) return;
  const uint64_t count = ++detachCount_;
  std::weak_ptr<EditorHost> weak = shared_from_this();
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                               static_cast<int64_t>(kWarmSeconds * 1e9)),
                 dispatch_get_main_queue(), ^{
                   auto self = weak.lock();
                   if (self != nullptr && !self->anyView() &&
                       self->detachCount_ == count) {
                     self->stopProcess();
                   }
                 });
}

// Sends the instance's welcome, which makes the editor show a view for it,
// then its place.
void EditorHost::open(uint32_t instance) {
  const auto it = clients_.find(instance);
  if (it == clients_.end() || it->second.view == nullptr) return;
  Plugin* plugin = it->second.plugin;
  aud::Json welcome = message("welcome");
  welcome.set("name", aud::Json::ofString(plugin->settings().name));
  welcome.set("version", number(kProtocolVersion));
  welcome.set("params", welcomeParams(*plugin));
  welcome.set("presets", welcomePresets(*plugin));
  welcome.set("preset", number(plugin->preset()));
  const aud::Json place = it->second.view->place();
  for (const char* key : {"width", "height", "scale"}) {
    const aud::Json* value = place.find(key);
    welcome.set(key, number(value != nullptr ? value->number : 0));
  }
  send(instance, welcome);
  send(instance, place);
  send(instance, message("show"));
}

void EditorHost::startTimer() {
  if (timer_ != nil) return;
  std::weak_ptr<EditorHost> weak = shared_from_this();
  timer_ = [NSTimer timerWithTimeInterval:kVisibilityPeriod
                                  repeats:YES
                                    block:^(NSTimer*) {
                                      if (auto self = weak.lock()) self->checkVisibility();
                                    }];
  [[NSRunLoop mainRunLoop] addTimer:timer_ forMode:NSRunLoopCommonModes];
}

void EditorHost::stopTimer() {
  [timer_ invalidate];
  timer_ = nil;
}

void EditorHost::checkVisibility() {
  if (!ready_) return;
  for (const auto& entry : clients_) {
    if (entry.second.view != nullptr) entry.second.view->checkVisible();
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
          if (connected) {
            dispatch_async(dispatch_get_main_queue(), ^{
              if (auto self = weak.lock()) self->connection_ = connection;
            });
            return;
          }
          dispatch_async(dispatch_get_main_queue(), ^{
            if (auto self = weak.lock()) self->connectionLost(connection);
          });
        });
    if (!server_->startPaired()) {
      logError("The editor's socket does not start");
      server_.reset();
      return;
    }
  }
  if (surfaces_ == nullptr) {
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
    const std::string& group = plugin->settings().appGroup;
    if (!surfaces_->start(group.empty() ? kDefaultMachPrefix : group)) {
      logError("The editor's Mach port does not register");
      surfaces_.reset();
      return;
    }
  }
  surfaces_->reset();
  spawn(plugin);
}

bool EditorHost::spawn(Plugin* plugin) {
  const std::string executable = editorExecutable(plugin->settings().editor);
  if (executable.empty()) {
    logError("The editor " + plugin->settings().editor + " is missing");
    return false;
  }
  const int pairFd = server_->connectPair();
  if (pairFd < 0) {
    logError("The editor's socket pair does not open");
    return false;
  }
  token_ = randomToken();
  std::vector<std::string> args = {
      executable,
      "--fd", "3",
      "--token", token_,
      "--instance", std::to_string(plugin->instance()),
      "--mach", surfaces_->name(),
  };
  std::vector<char*> argv;
  for (std::string& arg : args) argv.push_back(arg.data());
  argv.push_back(nullptr);
  // The editor inherits its end of the pair as fd 3 and nothing else of the
  // DAW: no sockets, pipes or files of other plugins; it logs to the
  // unified log.
  posix_spawn_file_actions_t actions;
  posix_spawn_file_actions_init(&actions);
  posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0);
  // A test that sets AUD_VST3_LOG gets the editor's lines there too.
  const std::string log = logFile();
  if (log.empty()) {
    posix_spawn_file_actions_addopen(&actions, STDOUT_FILENO, "/dev/null", O_WRONLY, 0);
  } else {
    posix_spawn_file_actions_addopen(&actions, STDOUT_FILENO, log.c_str(),
                                     O_WRONLY | O_CREAT | O_APPEND, 0644);
  }
  posix_spawn_file_actions_adddup2(&actions, STDOUT_FILENO, STDERR_FILENO);
  posix_spawn_file_actions_adddup2(&actions, pairFd, 3);
  posix_spawnattr_t attributes;
  posix_spawnattr_init(&attributes);
  posix_spawnattr_setflags(&attributes, POSIX_SPAWN_CLOEXEC_DEFAULT);
  pid_t pid = 0;
  const int result = posix_spawn(&pid, executable.c_str(), &actions,
                                 &attributes, argv.data(), environ);
  posix_spawnattr_destroy(&attributes);
  posix_spawn_file_actions_destroy(&actions);
  close(pairFd);
  if (result != 0) {
    logError("The editor does not start: posix_spawn " + std::to_string(result));
    return false;
  }
  pid_ = pid;
  alive_ = std::make_shared<bool>(true);
  logInfo("The editor " + std::to_string(pid) + " starts");
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
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, kHelloTimeoutNs),
                 dispatch_get_main_queue(), ^{
                   auto self = weak.lock();
                   if (self == nullptr || self->pid_ != pid || self->ready_ || !*alive) {
                     return;
                   }
                   logError("The editor said no hello");
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
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, kKillGraceNs),
                 dispatch_get_main_queue(), ^{
                   if (*alive) kill(pid, SIGKILL);
                 });
}

void EditorHost::stopProcess() {
  endGestures();
  releaseNotes();
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
  if (failedStarts_ >= kMaxFailedStarts) {
    logError("The editor gave up after five starts without a hello");
    return;
  }
  const int64_t wait =
      std::max<int64_t>(0, lastRestart_ + kRestartIntervalNs - nowNs());
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
  if (pid != pid_) return;
  logInfo("The editor exited with status " + std::to_string(status));
  pid_ = 0;
  if (!ready_) ++failedStarts_;
  ready_ = false;
  endGestures();
  releaseNotes();
  if (server_ != nullptr && connection_ != 0) server_->disconnect(connection_);
  connection_ = 0;
  // A crashed editor of an open view comes back.
  if (anyView()) scheduleRestart();
}

void EditorHost::releaseNotes() {
  for (const auto& entry : clients_) {
    const size_t released = entry.second.plugin->releaseEditorNotes();
    if (released > 0) {
      logInfo("Instance " + std::to_string(entry.first) + ": " + std::to_string(released) +
              " notes of the editor end without it");
    }
  }
}

void EditorHost::handle(const aud::Json& json, uint64_t connection) {
  const aud::Json* type = json.find("type");
  if (type == nullptr || !type->isString()) return;
  const std::string& kind = type->string;
  if (kind == "hello") {
    // A hello of a stopped editor, still queued, finds no server or token.
    if (server_ == nullptr || pid_ <= 0 || token_.empty() ||
        connection != connection_) {
      return;
    }
    const aud::Json* token = json.find("token");
    if (token == nullptr || token->string != token_) {
      logError("The editor said hello with a wrong token");
      server_->disconnect(connection);
      return;
    }
    server_->authenticate(connection);
    failedStarts_ = 0;
    ready_ = true;
    logInfo("The editor said hello");
    for (const auto& entry : clients_) {
      if (entry.second.view != nullptr) open(entry.first);
    }
    return;
  }
  if (!ready_ || connection != connection_) return;
  const std::optional<int64_t> instance =
      integerIn(json, "instance", 0, std::numeric_limits<uint32_t>::max());
  if (!instance) return;
  const auto it = clients_.find(static_cast<uint32_t>(*instance));
  if (it == clients_.end()) return;
  Plugin* plugin = it->second.plugin;
  EditorView* view = it->second.view;
  if (kind == "midi") {
    const aud::Json* bytes = json.find("bytes");
    if (bytes == nullptr || !bytes->isArray() ||
        bytes->array.size() > kMaxMidiBytes) {
      return;
    }
    std::vector<uint8_t> midi;
    midi.reserve(bytes->array.size());
    for (const aud::Json& byte : bytes->array) {
      if (!byte.isInteger() || byte.integer() < 0 || byte.integer() > 255) return;
      midi.push_back(static_cast<uint8_t>(byte.integer()));
    }
    if (!plugin->editorMidi(midi)) logError("The editor's MIDI overflowed");
    return;
  }
  if (kind == "selectPreset") {
    const std::optional<int64_t> index = integerIn(
        json, "index", 0, static_cast<int64_t>(plugin->settings().presets.size()) - 1);
    if (index) plugin->selectPreset(static_cast<uint32_t>(*index), view);
    return;
  }
  if (kind == "command" || kind == "gesture") {
    // Edits belong to a view: those of a closed one were ended with it.
    if (view == nullptr) return;
    const aud::Json* command = kind == "command" ? json.find("command") : &json;
    if (command == nullptr) return;
    const std::optional<int64_t> node =
        integerIn(*command, "node", std::numeric_limits<int32_t>::min(),
                  std::numeric_limits<int32_t>::max());
    const std::optional<int64_t> index = integerIn(
        *command, "paramIndex", 0, std::numeric_limits<uint32_t>::max());
    if (!node || !index || plugin->engine() == nullptr) return;
    const EngineParam* param = nullptr;
    for (const EngineParam& p : plugin->engine()->params()) {
      if (p.node == *node && p.index == static_cast<uint32_t>(*index)) param = &p;
    }
    // Only the parameters the DAW sees.
    if (param == nullptr || plugin->mapping(param->id) == nullptr) return;
    if (kind == "gesture") {
      const aud::Json* phase = json.find("phase");
      if (phase != nullptr && phase->string == "begin") plugin->editBegin(param->id, view);
      if (phase != nullptr && phase->string == "end") plugin->editEnd(param->id, view);
      return;
    }
    const aud::Json* name = command->find("command");
    const aud::Json* value = command->find("value");
    if (name == nullptr || name->string != "setParam" || value == nullptr ||
        !value->isNumber()) {
      return;
    }
    const ParamMapping* m = plugin->mapping(param->id);
    // Clamped before it becomes a float, which cannot hold every number.
    const double plain =
        std::min<double>(m->max, std::max<double>(m->min, value->number));
    plugin->edit(param->id, m->toNormalized(static_cast<float>(plain)), view);
    return;
  }
  if (kind == "cursor") {
    const aud::Json* cursor = json.find("kind");
    if (view != nullptr && cursor != nullptr) view->setCursor(cursor->string);
    return;
  }
}

// #############################################################################
IPlugView* createEditorView(Plugin* plugin) { return new EditorView(plugin); }

}  // namespace aud_vst3
