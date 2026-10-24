// @license
// Copyright (c) Audanika. All Rights Reserved.
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

// Work for the DAW's UI thread from another thread (ticket 37; Windows in
// ticket 38), e.g. the values of a preset the control thread applied. macOS
// has the main queue. Windows has no queue of the UI thread for a DLL, so
// the first plugin instance creates a message-only window on it, which the
// last one destroys; the DAW calls initialize() and terminate() on its UI
// thread.

#ifndef AUD_VST3_UI_THREAD_HPP
#define AUD_VST3_UI_THREAD_HPP

namespace aud_vst3 {

// #############################################################################
// [UI thread] Holds what runOnUiThread() needs; each call is paired with a
// releaseUiThread(), from initialize() and terminate().
void retainUiThread();

// #############################################################################
// [UI thread] Gives up what retainUiThread() held. The last release runs
// the tasks still waiting, so that each frees what it carries.
void releaseUiThread();

// #############################################################################
// [any thread but realtime] Runs `task(context)` on the UI thread later;
// false when it cannot, which leaves `context` to the caller. Only while a
// retainUiThread() holds.
bool runOnUiThread(void (*task)(void*), void* context);

}  // namespace aud_vst3

#endif  // AUD_VST3_UI_THREAD_HPP
