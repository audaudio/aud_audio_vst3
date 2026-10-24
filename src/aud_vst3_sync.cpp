// @license
// Copyright (c) Audanika. All Rights Reserved.
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

#include "aud_vst3_sync.hpp"

#if _WIN32
#ifndef NOMINMAX
#define NOMINMAX
#endif
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <windows.h>
#else
#include <dispatch/dispatch.h>
#endif

namespace aud_vst3 {

#if _WIN32

// .............................................................................
Semaphore::Semaphore()
    : handle_(CreateSemaphoreW(nullptr, 0, 0x7fffffff, nullptr)) {}

// .............................................................................
Semaphore::~Semaphore() { CloseHandle(static_cast<HANDLE>(handle_)); }

// .............................................................................
void Semaphore::post() { ReleaseSemaphore(static_cast<HANDLE>(handle_), 1, nullptr); }

// .............................................................................
bool Semaphore::waitFor(int64_t timeoutNs) {
  if (timeoutNs < 0) timeoutNs = 0;
  // Rounded up, so that a wait of less than a millisecond still waits.
  const auto ms = static_cast<DWORD>((timeoutNs + 999'999) / 1'000'000);
  return WaitForSingleObject(static_cast<HANDLE>(handle_), ms) == WAIT_OBJECT_0;
}

#else

namespace {

// In C++ a dispatch object is a plain pointer, released by hand.
dispatch_semaphore_t semaphoreOf(void* handle) {
  return static_cast<dispatch_semaphore_t>(handle);
}

}  // namespace

// .............................................................................
Semaphore::Semaphore() : handle_(dispatch_semaphore_create(0)) {}

// .............................................................................
Semaphore::~Semaphore() {
  dispatch_semaphore_t semaphore = semaphoreOf(handle_);
  // A dispatch semaphore must not be released below its initial count.
  while (dispatch_semaphore_wait(semaphore, DISPATCH_TIME_NOW) == 0) {
  }
  dispatch_release(semaphore);
}

// .............................................................................
void Semaphore::post() { dispatch_semaphore_signal(semaphoreOf(handle_)); }

// .............................................................................
bool Semaphore::waitFor(int64_t timeoutNs) {
  if (timeoutNs < 0) timeoutNs = 0;
  return dispatch_semaphore_wait(semaphoreOf(handle_),
                                 dispatch_time(DISPATCH_TIME_NOW, timeoutNs)) == 0;
}

#endif

}  // namespace aud_vst3
