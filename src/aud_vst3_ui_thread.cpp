// @license
// Copyright (c) Audanika. All Rights Reserved.
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

#include "aud_vst3_ui_thread.hpp"

#if _WIN32
#ifndef NOMINMAX
#define NOMINMAX
#endif
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <windows.h>

#include <atomic>
#else
#include <dispatch/dispatch.h>
#endif

namespace aud_vst3 {

#if _WIN32

namespace {

// The message that carries a task: the function in wParam, its context in
// lParam.
constexpr UINT kTaskMessage = WM_APP + 0x41;

// The window and the count of the instances that hold it (UI thread).
HWND window = nullptr;
int holders = 0;
ATOM windowClass = 0;
// The window as the other threads see it.
std::atomic<HWND> postWindow{nullptr};

LRESULT CALLBACK windowProc(HWND hwnd, UINT message, WPARAM wParam,
                            LPARAM lParam) {
  if (message == kTaskMessage) {
    reinterpret_cast<void (*)(void*)>(wParam)(reinterpret_cast<void*>(lParam));
    return 0;
  }
  return DefWindowProcW(hwnd, message, wParam, lParam);
}

// The module that holds this code: the plugin's DLL.
HINSTANCE module() {
  HMODULE handle = nullptr;
  GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS |
                         GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
                     reinterpret_cast<LPCWSTR>(&windowProc), &handle);
  return handle;
}

}  // namespace

// .............................................................................
void retainUiThread() {
  if (holders++ > 0) return;
  WNDCLASSEXW info{};
  info.cbSize = sizeof(info);
  info.lpfnWndProc = windowProc;
  info.hInstance = module();
  // One class per DLL: two plugins built on the shell keep their own.
  wchar_t name[64];
  wsprintfW(name, L"AudVst3UiThread%p", static_cast<void*>(info.hInstance));
  info.lpszClassName = name;
  windowClass = RegisterClassExW(&info);
  window = CreateWindowExW(0, MAKEINTATOM(windowClass), L"", 0, 0, 0, 0, 0,
                           HWND_MESSAGE, nullptr, module(), nullptr);
  postWindow.store(window, std::memory_order_release);
}

// .............................................................................
void releaseUiThread() {
  if (holders == 0 || --holders > 0) return;
  postWindow.store(nullptr, std::memory_order_release);
  // The tasks still waiting run now: each frees what it carries, and none
  // may run once the DAW unloads the DLL that holds windowProc.
  MSG message;
  while (PeekMessageW(&message, window, kTaskMessage, kTaskMessage, PM_REMOVE)) {
    DispatchMessageW(&message);
  }
  DestroyWindow(window);
  window = nullptr;
  // Windows keeps the class of a DLL past its unload; a new load of the DLL
  // registers it anew.
  UnregisterClassW(MAKEINTATOM(windowClass), module());
  windowClass = 0;
}

// .............................................................................
bool runOnUiThread(void (*task)(void*), void* context) {
  const HWND target = postWindow.load(std::memory_order_acquire);
  return target != nullptr &&
         PostMessageW(target, kTaskMessage, reinterpret_cast<WPARAM>(task),
                      reinterpret_cast<LPARAM>(context)) != 0;
}

#else

// .............................................................................
void retainUiThread() {}

// .............................................................................
void releaseUiThread() {}

// .............................................................................
bool runOnUiThread(void (*task)(void*), void* context) {
  dispatch_async_f(dispatch_get_main_queue(), context, task);
  return true;
}

#endif

}  // namespace aud_vst3
