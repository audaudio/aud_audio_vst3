// @license
// Copyright (c) Audanika. All Rights Reserved.
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

// The editor of the plugin on Windows (ticket 38, plugin-009): the
// executable plugin.json names as `editor` - a location such as
// `containing-folder:App.exe`, the app that ships the plugin -,
// started with `--plugin-editor` for every open view of an instance.
//
// Windows lets a window of one process be the child of a window of another,
// so the editor draws into the plugin's view itself: the view is a child
// window of the DAW's, and the editor makes its Flutter view a child of it.
// Input, focus, cursor and scaling are those of Windows; nothing is copied
// or forwarded. The editor learns the view's window from `--parent` and
// fills it whenever a place arrives.
//
// The channel is the shell protocol over a Unix domain socket in %TEMP%
// (SocketServer::start), whose path, a random token and the instance the
// editor gets on its command line; Windows hands a process no socket pair.
// As on macOS the editor says hello with the token and gets the instance's
// welcome; it sends the MIDI of its play surface, the preset it chose and
// its parameter edits with their gestures, and the plugin sends the changes
// of parameters and presets.
//
// The editor runs in a job object that ends it with the DAW. It quits when
// the socket ends; one that does not is ended with the job. An editor that
// exits while its view is open is started again, at most every 2 s and five
// times in a row without a hello. Nothing waits for the editor: the
// socket's outbox is bounded, and a timer of the view looks after the
// process.

#include "aud_vst3_plugin.hpp"

#ifndef NOMINMAX
#define NOMINMAX
#endif
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <windows.h>

#include <algorithm>
#include <cstring>
#include <limits>
#include <memory>
#include <optional>
#include <random>
#include <string>
#include <vector>

#include "aud_clock.h"
#include "aud_json.hpp"
#include "pluginterfaces/gui/iplugviewcontentscalesupport.h"
#include "public.sdk/source/common/pluginview.h"

#include "aud_vst3_bundle.hpp"
#include "aud_vst3_socket.hpp"
#include "aud_vst3_ui_thread.hpp"

namespace aud_vst3 {

using namespace Steinberg;

namespace {

// The version of the shell protocol (audShellProtocolVersion).
constexpr int kProtocolVersion = 3;

// How long a started editor may take to say hello before it is ended and
// started again.
constexpr int64_t kHelloTimeoutNs = 10'000'000'000;

// How long a closing view waits for its editor to quit before the job ends
// it.
constexpr DWORD kQuitGraceMs = 300;

// The starts in a row without a hello after which no editor is started.
constexpr int kMaxFailedStarts = 5;

// The shortest time from one start of an editor to the next.
constexpr int64_t kRestartIntervalNs = 2'000'000'000;

// How often the view looks after its editor.
constexpr UINT kTickMs = 100;

// The most MIDI bytes one message of the editor may carry.
constexpr size_t kMaxMidiBytes = 4096;

// The background of the view until the editor draws.
constexpr COLORREF kBackground = RGB(28, 31, 36);

int64_t nowNs() { return aud_clock_now_ns(); }

std::wstring wide(const std::string& text) {
  if (text.empty()) return {};
  const int length = MultiByteToWideChar(CP_UTF8, 0, text.data(),
                                         static_cast<int>(text.size()), nullptr, 0);
  std::wstring result(static_cast<size_t>(length), L'\0');
  MultiByteToWideChar(CP_UTF8, 0, text.data(), static_cast<int>(text.size()),
                      &result[0], length);
  return result;
}

std::string utf8(const std::wstring& text) {
  if (text.empty()) return {};
  const int length =
      WideCharToMultiByte(CP_UTF8, 0, text.data(), static_cast<int>(text.size()),
                          nullptr, 0, nullptr, nullptr);
  std::string result(static_cast<size_t>(length), '\0');
  WideCharToMultiByte(CP_UTF8, 0, text.data(), static_cast<int>(text.size()),
                      &result[0], length, nullptr, nullptr);
  return result;
}

std::string randomToken() {
  std::random_device random;
  char token[33];
  std::snprintf(token, sizeof(token), "%08x%08x%08x%08x", random(), random(),
                random(), random());
  return token;
}

// The folder of the editor's socket: %TEMP%, without its trailing separator.
std::string socketDirectory() {
  wchar_t path[MAX_PATH + 1];
  const DWORD length = GetTempPathW(MAX_PATH + 1, path);
  std::wstring directory(path, length);
  while (directory.size() > 3 && directory.back() == L'\\') directory.pop_back();
  return utf8(directory);
}

// `arg` quoted for a command line as CommandLineToArgvW reads it.
std::wstring quoted(const std::wstring& arg) {
  std::wstring result = L"\"";
  size_t backslashes = 0;
  for (const wchar_t c : arg) {
    if (c == L'\\') {
      ++backslashes;
      continue;
    }
    result.append(c == L'"' ? backslashes * 2 + 1 : backslashes, L'\\');
    backslashes = 0;
    result += c;
  }
  result.append(backslashes * 2, L'\\');
  return result + L"\"";
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

// The module that holds this code: the plugin's DLL.
HINSTANCE module() {
  HMODULE handle = nullptr;
  GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS |
                         GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
                     reinterpret_cast<LPCWSTR>(&module), &handle);
  return handle;
}

// The scale of the screens when no host tells it: the system's DPI.
double systemScale() { return GetDpiForSystem() / 96.0; }

class EditorView;

// The window class of the views, registered while one exists (UI thread).
ATOM viewClass = 0;
int viewClassUsers = 0;

LRESULT CALLBACK viewProc(HWND hwnd, UINT message, WPARAM wParam, LPARAM lParam);

// #############################################################################
// A message of the editor on its way to the UI thread.
struct Received {
  EditorView* view;
  std::shared_ptr<bool> alive;
  aud::Json json;
  uint64_t connection;
  bool lost;
};

// #############################################################################
// The plugin's view on Windows; see above. Everything but the socket's
// thread runs on the DAW's UI thread.
class EditorView : public CPluginView,
                   public IPlugViewContentScaleSupport,
                   public PluginObserver {
 public:
  // ...........................................................................
  // Creates the view of `plugin`, which it holds and observes.
  explicit EditorView(Plugin* plugin) : CPluginView(nullptr), plugin_(plugin) {
    setRect(sizeAt(scale_));
    // The view holds the plugin, as the SDK's EditorView holds its
    // controller: a DAW may release the plugin before the view.
    plugin_->addRef();
    plugin_->addObserver(this);
  }

  // ...........................................................................
  // Tears the view down and lets the plugin go.
  ~EditorView() override {
    teardown();
    plugin_->removeObserver(this);
    plugin_->release();
  }

  // ###########################################################################
  // IPlugView

  tresult PLUGIN_API isPlatformTypeSupported(FIDString type) SMTG_OVERRIDE {
    return std::strcmp(type, kPlatformTypeHWND) == 0 ? kResultTrue : kResultFalse;
  }

  tresult PLUGIN_API attached(void* parent, FIDString type) SMTG_OVERRIDE {
    if (isPlatformTypeSupported(type) != kResultTrue || parent == nullptr) {
      return kResultFalse;
    }
    if (viewClassUsers++ == 0) {
      WNDCLASSEXW info{};
      info.cbSize = sizeof(info);
      info.lpfnWndProc = viewProc;
      info.hInstance = module();
      info.hCursor = LoadCursorW(nullptr, IDC_ARROW);
      wchar_t name[64];
      wsprintfW(name, L"AudVst3Editor%p", static_cast<void*>(info.hInstance));
      info.lpszClassName = name;
      viewClass = RegisterClassExW(&info);
    }
    window_ = CreateWindowExW(0, MAKEINTATOM(viewClass), L"",
                              WS_CHILD | WS_VISIBLE | WS_CLIPCHILDREN, 0, 0,
                              rect.getWidth(), rect.getHeight(),
                              static_cast<HWND>(parent), nullptr, module(), nullptr);
    if (window_ == nullptr) {
      releaseClass();
      return kResultFalse;
    }
    SetWindowLongPtrW(window_, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(this));
    SetTimer(window_, 1, kTickMs, nullptr);
    failedStarts_ = 0;
    startEditor();
    return CPluginView::attached(parent, type);
  }

  tresult PLUGIN_API removed() SMTG_OVERRIDE {
    teardown();
    return CPluginView::removed();
  }

  tresult PLUGIN_API onSize(ViewRect* newSize) SMTG_OVERRIDE {
    if (newSize != nullptr && window_ != nullptr) {
      SetWindowPos(window_, nullptr, 0, 0, newSize->getWidth(), newSize->getHeight(),
                   SWP_NOZORDER | SWP_NOACTIVATE | SWP_NOMOVE);
    }
    const tresult result = CPluginView::onSize(newSize);
    sendPlace();
    return result;
  }

  tresult PLUGIN_API canResize() SMTG_OVERRIDE { return kResultTrue; }

  tresult PLUGIN_API checkSizeConstraint(ViewRect* r) SMTG_OVERRIDE {
    if (r == nullptr) return kInvalidArgument;
    const Settings& settings = plugin_->settings();
    const auto minWidth = static_cast<int32>(settings.editorMinWidth * scale_);
    const auto minHeight = static_cast<int32>(settings.editorMinHeight * scale_);
    if (r->getWidth() < minWidth) r->right = r->left + minWidth;
    if (r->getHeight() < minHeight) r->bottom = r->top + minHeight;
    return kResultTrue;
  }

  // ###########################################################################
  // IPlugViewContentScaleSupport

  tresult PLUGIN_API setContentScaleFactor(ScaleFactor factor) SMTG_OVERRIDE {
    if (factor <= 0 || factor == scale_) return kResultTrue;
    const double ratio = factor / scale_;
    scale_ = factor;
    // The view keeps its size in points: in pixels it grows with the scale.
    ViewRect size(0, 0, static_cast<int32>(rect.getWidth() * ratio),
                  static_cast<int32>(rect.getHeight() * ratio));
    if (plugFrame != nullptr && window_ != nullptr) {
      plugFrame->resizeView(this, &size);
    } else {
      setRect(size);
    }
    sendPlace();
    return kResultTrue;
  }

  // ###########################################################################
  // PluginObserver

  void paramChanged(uint32_t id, double normalized) override {
    if (!ready_) return;
    const ParamMapping* m = plugin_->mapping(id);
    if (m == nullptr) return;
    aud::Json json = message("param");
    json.set("id", number(id));
    json.set("value", number(m->toPlain(normalized)));
    send(json);
  }

  void presetChanged(uint32_t index) override {
    if (!ready_) return;
    aud::Json json = message("preset");
    json.set("index", number(index));
    send(json);
  }

  // ###########################################################################
  // The window

  // ...........................................................................
  // [UI thread] Looks after the editor: an exit, a hello that does not come,
  // a restart that is due, a change of the visibility.
  void tick() {
    if (process_ != nullptr && WaitForSingleObject(process_, 0) == WAIT_OBJECT_0) {
      exited();
    }
    if (process_ != nullptr && !ready_ && nowNs() - startedNs_ > kHelloTimeoutNs) {
      logError("The editor said no hello");
      endProcess();
      exited();
    }
    if (process_ == nullptr && window_ != nullptr && failedStarts_ < kMaxFailedStarts &&
        nowNs() >= restartNs_) {
      startEditor();
    }
    const bool seen = window_ != nullptr && IsWindowVisible(window_) != 0;
    if (seen != sentVisible_) sendPlace();
  }

  // ...........................................................................
  // [UI thread] Paints the background until the editor's child covers it.
  void paint() {
    PAINTSTRUCT paint;
    HDC dc = BeginPaint(window_, &paint);
    HBRUSH brush = CreateSolidBrush(kBackground);
    FillRect(dc, &paint.rcPaint, brush);
    DeleteObject(brush);
    EndPaint(window_, &paint);
  }

  // ###########################################################################
  // FUnknown

  OBJ_METHODS(EditorView, CPluginView)
  DEFINE_INTERFACES
  DEF_INTERFACE(IPlugViewContentScaleSupport)
  END_DEFINE_INTERFACES(CPluginView)
  REFCOUNT_METHODS(CPluginView)

 private:
  // The size of the view in pixels at `scale`, from plugin.json.
  ViewRect sizeAt(double scale) const {
    const Settings& settings = plugin_->settings();
    return ViewRect(0, 0, static_cast<int32>(settings.editorWidth * scale),
                    static_cast<int32>(settings.editorHeight * scale));
  }

  // The geometry of the view for the editor, in pixels.
  aud::Json place() {
    aud::Json json = message("place");
    RECT client{};
    if (window_ != nullptr) GetClientRect(window_, &client);
    sentVisible_ = window_ != nullptr && IsWindowVisible(window_) != 0;
    json.set("x", number(0));
    json.set("y", number(0));
    json.set("width", number(client.right - client.left));
    json.set("height", number(client.bottom - client.top));
    json.set("scale", number(scale_));
    json.set("window", number(static_cast<double>(reinterpret_cast<uintptr_t>(window_))));
    json.set("visible", aud::Json::ofBool(sentVisible_));
    return json;
  }

  void sendPlace() {
    if (ready_) send(place());
  }

  void send(aud::Json json) {
    if (server_ == nullptr) return;
    json.set("instance", number(plugin_->instance()));
    server_->send(json);
  }

  // Starts the socket and the editor process for the view.
  void startEditor() {
    const std::string executable =
        locate(plugin_->settings().editor, resolvedBundlePath());
    restartNs_ = nowNs() + kRestartIntervalNs;
    if (!isFile(executable)) {
      logError("The editor " + plugin_->settings().editor + " is missing");
      failedStarts_ = kMaxFailedStarts;
      return;
    }
    alive_ = std::make_shared<bool>(true);
    EditorView* self = this;
    std::shared_ptr<bool> alive = alive_;
    // The socket's thread hands everything to the UI thread.
    const auto post = [self, alive](aud::Json json, uint64_t connection, bool lost) {
      auto* received = new Received{self, alive, std::move(json), connection, lost};
      const bool posted = runOnUiThread(
          [](void* context) {
            std::unique_ptr<Received> received(static_cast<Received*>(context));
            if (!*received->alive) return;
            if (received->lost) {
              received->view->connectionLost(received->connection);
            } else {
              received->view->handle(received->json, received->connection);
            }
          },
          received);
      if (!posted) delete received;
    };
    server_ = std::make_unique<SocketServer>(
        [post](const aud::Json& json, uint64_t connection) { post(json, connection, false); },
        [post](bool connected, uint64_t connection) {
          if (!connected) post(aud::Json(), connection, true);
        });
    if (!server_->start(socketDirectory())) {
      logError("The editor's socket does not start");
      server_.reset();
      failedStarts_ = kMaxFailedStarts;
      return;
    }
    token_ = randomToken();
    if (!spawn(executable)) {
      ++failedStarts_;
      server_.reset();
    }
  }

  bool spawn(const std::string& executable) {
    std::wstring commandLine = quoted(wide(executable));
    for (const std::string& arg :
         {std::string("--plugin-editor"), std::string("--socket"), server_->path(),
          std::string("--token"), token_, std::string("--instance"),
          std::to_string(plugin_->instance()), std::string("--parent"),
          std::to_string(reinterpret_cast<uintptr_t>(window_))}) {
      commandLine += L" " + quoted(wide(arg));
    }
    job_ = CreateJobObjectW(nullptr, nullptr);
    if (job_ != nullptr) {
      // The editor ends with the DAW, also when the DAW crashes.
      JOBOBJECT_EXTENDED_LIMIT_INFORMATION limits{};
      limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
      SetInformationJobObject(job_, JobObjectExtendedLimitInformation, &limits,
                              sizeof(limits));
    }
    // The editor inherits no handle of the DAW, but the log file a test
    // names with AUD_VST3_LOG as its output, as on macOS.
    STARTUPINFOEXW startup{};
    startup.StartupInfo.cb = sizeof(startup);
    HANDLE log = INVALID_HANDLE_VALUE;
    std::vector<char> attributes;
    if (!logFile().empty()) {
      SECURITY_ATTRIBUTES inheritable{sizeof(SECURITY_ATTRIBUTES), nullptr, TRUE};
      log = CreateFileW(wide(logFile()).c_str(), FILE_APPEND_DATA,
                        FILE_SHARE_READ | FILE_SHARE_WRITE, &inheritable, OPEN_ALWAYS,
                        FILE_ATTRIBUTE_NORMAL, nullptr);
    }
    if (log != INVALID_HANDLE_VALUE) {
      SIZE_T size = 0;
      InitializeProcThreadAttributeList(nullptr, 1, 0, &size);
      attributes.resize(size);
      startup.lpAttributeList =
          reinterpret_cast<LPPROC_THREAD_ATTRIBUTE_LIST>(attributes.data());
      InitializeProcThreadAttributeList(startup.lpAttributeList, 1, 0, &size);
      UpdateProcThreadAttribute(startup.lpAttributeList, 0,
                                PROC_THREAD_ATTRIBUTE_HANDLE_LIST, &log, sizeof(log),
                                nullptr, nullptr);
      startup.StartupInfo.dwFlags = STARTF_USESTDHANDLES;
      startup.StartupInfo.hStdOutput = log;
      startup.StartupInfo.hStdError = log;
    }
    PROCESS_INFORMATION info{};
    const std::wstring application = wide(executable);
    const BOOL started = CreateProcessW(
        application.c_str(), &commandLine[0], nullptr, nullptr,
        log != INVALID_HANDLE_VALUE,
        CREATE_SUSPENDED | CREATE_NO_WINDOW | EXTENDED_STARTUPINFO_PRESENT, nullptr,
        nullptr, &startup.StartupInfo, &info);
    if (startup.lpAttributeList != nullptr) {
      DeleteProcThreadAttributeList(startup.lpAttributeList);
    }
    if (log != INVALID_HANDLE_VALUE) CloseHandle(log);
    if (!started) {
      logError("The editor does not start: " + std::to_string(GetLastError()));
      if (job_ != nullptr) CloseHandle(job_);
      job_ = nullptr;
      return false;
    }
    if (job_ != nullptr) AssignProcessToJobObject(job_, info.hProcess);
    ResumeThread(info.hThread);
    CloseHandle(info.hThread);
    process_ = info.hProcess;
    startedNs_ = nowNs();
    logInfo("The editor " + std::to_string(info.dwProcessId) + " starts for instance " +
            std::to_string(plugin_->instance()));
    return true;
  }

  // [UI thread] A message of the editor.
  void handle(const aud::Json& json, uint64_t connection) {
    const aud::Json* type = json.find("type");
    if (type == nullptr || !type->isString() || server_ == nullptr) return;
    const std::string& kind = type->string;
    if (kind == "hello") {
      const aud::Json* token = json.find("token");
      if (token == nullptr || token_.empty() || token->string != token_) {
        logError("The editor said hello with a wrong token");
        server_->disconnect(connection);
        return;
      }
      server_->authenticate(connection);
      connection_ = connection;
      ready_ = true;
      failedStarts_ = 0;
      logInfo("The editor said hello");
      open();
      return;
    }
    if (!ready_ || connection != connection_) return;
    const std::optional<int64_t> instance =
        integerIn(json, "instance", 0, std::numeric_limits<uint32_t>::max());
    if (!instance || static_cast<uint32_t>(*instance) != plugin_->instance()) return;
    if (kind == "midi") {
      const aud::Json* bytes = json.find("bytes");
      if (bytes == nullptr || !bytes->isArray() || bytes->array.size() > kMaxMidiBytes) {
        return;
      }
      std::vector<uint8_t> midi;
      midi.reserve(bytes->array.size());
      for (const aud::Json& byte : bytes->array) {
        if (!byte.isInteger() || byte.integer() < 0 || byte.integer() > 255) return;
        midi.push_back(static_cast<uint8_t>(byte.integer()));
      }
      if (!plugin_->editorMidi(midi)) logError("The editor's MIDI overflowed");
      // A test that sets AUD_VST3_LOG gets every message the editor played.
      if (!logFile().empty()) {
        std::string text = "Instance " + std::to_string(plugin_->instance()) + " MIDI";
        char hex[4];
        for (const uint8_t byte : midi) {
          std::snprintf(hex, sizeof(hex), " %02x", byte);
          text += hex;
        }
        logInfo(text);
      }
      return;
    }
    if (kind == "settings") {
      // The settings of the instance, kept with the project (ticket 38).
      const aud::Json* settings = json.find("settings");
      if (settings != nullptr && settings->isString() &&
          !plugin_->setEditorSettings(settings->string)) {
        logError("The editor's settings are too long");
      }
      return;
    }
    if (kind == "selectPreset") {
      const std::optional<int64_t> index = integerIn(
          json, "index", 0, static_cast<int64_t>(plugin_->settings().presets.size()) - 1);
      if (index) plugin_->selectPreset(static_cast<uint32_t>(*index), this);
      return;
    }
    if (kind == "command" || kind == "gesture") {
      const aud::Json* command = kind == "command" ? json.find("command") : &json;
      if (command == nullptr) return;
      const std::optional<int64_t> node =
          integerIn(*command, "node", std::numeric_limits<int32_t>::min(),
                    std::numeric_limits<int32_t>::max());
      const std::optional<int64_t> index =
          integerIn(*command, "paramIndex", 0, std::numeric_limits<uint32_t>::max());
      if (!node || !index || plugin_->engine() == nullptr) return;
      const EngineParam* param = nullptr;
      for (const EngineParam& p : plugin_->engine()->params()) {
        if (p.node == *node && p.index == static_cast<uint32_t>(*index)) param = &p;
      }
      // Only the parameters the DAW sees.
      if (param == nullptr || plugin_->mapping(param->id) == nullptr) return;
      if (kind == "gesture") {
        const aud::Json* phase = json.find("phase");
        if (phase != nullptr && phase->string == "begin") plugin_->editBegin(param->id, this);
        if (phase != nullptr && phase->string == "end") plugin_->editEnd(param->id, this);
        return;
      }
      const aud::Json* name = command->find("command");
      const aud::Json* value = command->find("value");
      if (name == nullptr || name->string != "setParam" || value == nullptr ||
          !value->isNumber()) {
        return;
      }
      const ParamMapping* m = plugin_->mapping(param->id);
      // Clamped before it becomes a float, which cannot hold every number.
      const double plain = std::min<double>(m->max, std::max<double>(m->min, value->number));
      plugin_->edit(param->id, m->toNormalized(static_cast<float>(plain)), this);
    }
    // The cursor is the editor's own window's on Windows.
  }

  // Sends the welcome, which makes the editor show the instance, then the
  // place.
  void open() {
    aud::Json welcome = message("welcome");
    welcome.set("name", aud::Json::ofString(plugin_->settings().name));
    welcome.set("version", number(kProtocolVersion));
    welcome.set("params", welcomeParams(*plugin_));
    welcome.set("presets", welcomePresets(*plugin_));
    welcome.set("preset", number(plugin_->preset()));
    welcome.set("settings", aud::Json::ofString(plugin_->editorSettings()));
    const aud::Json geometry = place();
    for (const char* key : {"width", "height", "scale"}) {
      const aud::Json* value = geometry.find(key);
      welcome.set(key, number(value != nullptr ? value->number : 0));
    }
    send(welcome);
    send(geometry);
    send(message("show"));
  }

  // [UI thread] The editor's connection ended: it quit or crashed, or was
  // cut off because it read nothing. Its gestures and notes end; the
  // process ends, and the timer starts a new one while the view is open.
  void connectionLost(uint64_t connection) {
    if (connection == 0 || connection != connection_) return;
    ready_ = false;
    connection_ = 0;
    plugin_->endEdits(this);
    releaseNotes();
    endProcess();
  }

  // [UI thread] The editor process exited.
  void exited() {
    DWORD status = 0;
    if (process_ != nullptr) GetExitCodeProcess(process_, &status);
    logInfo("The editor exited with status " + std::to_string(status));
    if (!ready_) ++failedStarts_;
    if (failedStarts_ >= kMaxFailedStarts) {
      logError("The editor gave up after five starts without a hello");
    }
    ready_ = false;
    connection_ = 0;
    plugin_->endEdits(this);
    releaseNotes();
    closeProcess();
    server_.reset();
    restartNs_ = std::max(restartNs_, nowNs());
  }

  void releaseNotes() {
    const size_t released = plugin_->releaseEditorNotes();
    if (released > 0) {
      logInfo("Instance " + std::to_string(plugin_->instance()) + ": " +
              std::to_string(released) + " notes of the editor end without it");
    }
  }

  // Ends the process now, with its job.
  void endProcess() {
    if (process_ != nullptr) TerminateProcess(process_, 1);
  }

  void closeProcess() {
    if (process_ != nullptr) CloseHandle(process_);
    process_ = nullptr;
    // Closing the job ends an editor still running.
    if (job_ != nullptr) CloseHandle(job_);
    job_ = nullptr;
  }

  void releaseClass() {
    if (--viewClassUsers > 0) return;
    // Windows keeps the class of a DLL past its unload.
    UnregisterClassW(MAKEINTATOM(viewClass), module());
    viewClass = 0;
  }

  // Closes the editor and the window: the end of the socket makes the
  // editor quit, the job ends one that does not.
  void teardown() {
    // A view closed mid-gesture leaves no gesture open in the DAW.
    plugin_->endEdits(this);
    if (alive_ != nullptr) *alive_ = false;
    ready_ = false;
    connection_ = 0;
    server_.reset();
    if (process_ != nullptr) WaitForSingleObject(process_, kQuitGraceMs);
    releaseNotes();
    closeProcess();
    if (window_ != nullptr) {
      KillTimer(window_, 1);
      SetWindowLongPtrW(window_, GWLP_USERDATA, 0);
      DestroyWindow(window_);
      window_ = nullptr;
      releaseClass();
    }
  }

  Plugin* plugin_;
  HWND window_ = nullptr;
  double scale_ = systemScale();
  std::unique_ptr<SocketServer> server_;
  std::shared_ptr<bool> alive_;
  std::string token_;
  uint64_t connection_ = 0;
  bool ready_ = false;
  bool sentVisible_ = false;
  HANDLE process_ = nullptr;
  HANDLE job_ = nullptr;
  int64_t startedNs_ = 0;
  int64_t restartNs_ = 0;
  int failedStarts_ = 0;
};

LRESULT CALLBACK viewProc(HWND hwnd, UINT message, WPARAM wParam, LPARAM lParam) {
  auto* view = reinterpret_cast<EditorView*>(GetWindowLongPtrW(hwnd, GWLP_USERDATA));
  if (view != nullptr) {
    if (message == WM_TIMER) {
      view->tick();
      return 0;
    }
    if (message == WM_PAINT) {
      view->paint();
      return 0;
    }
  }
  if (message == WM_ERASEBKGND) return 1;
  return DefWindowProcW(hwnd, message, wParam, lParam);
}

}  // namespace

// #############################################################################
IPlugView* createEditorView(Plugin* plugin) {
  // Without an editor in plugin.json the DAW shows its generic view.
  if (plugin->settings().editor.empty()) return nullptr;
  return new EditorView(plugin);
}

}  // namespace aud_vst3
