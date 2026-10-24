// @license
// Copyright (c) Audanika. All Rights Reserved.
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

// The semaphore of the engine's control thread (ticket 37; Windows in
// ticket 38): the realtime thread posts it without blocking (script-001),
// the control thread and an offline block wait on it with a timeout. One
// implementation per platform, as aud_audio_script's aud_script_sync.hpp:
// a dispatch semaphore on Apple, a Win32 semaphore on Windows;
// std::counting_semaphore needs C++20. The handle stays opaque, so that no
// header of the plugin includes windows.h.

#ifndef AUD_VST3_SYNC_HPP
#define AUD_VST3_SYNC_HPP

#include <cstdint>

namespace aud_vst3 {

// #############################################################################
// A counting semaphore; see above.
class Semaphore {
 public:
  // ...........................................................................
  // Creates the semaphore with a count of 0.
  Semaphore();

  // ...........................................................................
  // Destroys the semaphore; nobody may wait on it.
  ~Semaphore();

  // ...........................................................................
  // Not copyable: the handle is the semaphore.
  Semaphore(const Semaphore&) = delete;
  Semaphore& operator=(const Semaphore&) = delete;

  // ...........................................................................
  // [realtime] Increments the count and wakes a waiter; never blocks.
  void post();

  // ...........................................................................
  // Waits until the count is positive or `timeoutNs` passed; true when the
  // count was taken.
  bool waitFor(int64_t timeoutNs);

 private:
  void* handle_;
};

}  // namespace aud_vst3

#endif  // AUD_VST3_SYNC_HPP
