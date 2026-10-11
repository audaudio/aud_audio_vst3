// @license
// Copyright (c) Audanika. All Rights Reserved.
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

// The synthetic drag of the latency measurement (ticket 24): a mouse down on
// the test knob, kTestSteps drags of kTestStepPoints at kTestPeriod - half of
// them up, half down - and a mouse up. The events go to the delegate of the
// view exactly as the window would deliver them, so every variant measures
// from the same input event.

#ifndef AUD_VST3_DRIVER_HPP
#define AUD_VST3_DRIVER_HPP

#ifdef __OBJC__
#import <Cocoa/Cocoa.h>

#include <functional>

#include "aud_vst3_objc.hpp"

namespace aud_vst3 {

// #############################################################################
// The synthetic drag in one view, driven by a timer on the host's UI thread.
class SyntheticDrag {
 public:
  // ...........................................................................
  // Creates a drag that does not run yet.
  SyntheticDrag() = default;

  // ...........................................................................
  // Stops the drag.
  ~SyntheticDrag();

  // ...........................................................................
  // Starts the drag in `view`: `prepare` runs first and sets the knob to
  // kTestStartValue, the mouse down follows half a second later; `done`
  // runs after the mouse up.
  void start(NSView* view, ViewDelegate* delegate,
             const std::function<void()>& prepare, std::function<void()> done);

  // ...........................................................................
  // Stops the drag where it is; `done` does not run.
  void stop();

  // ...........................................................................
  // Whether the drag runs.
  bool running() const { return timer_ != nil; }

 private:
  void step();
  NSEvent* event(NSEventType type, NSPoint location);

  NSView* __weak view_ = nil;
  ViewDelegate* delegate_ = nullptr;
  NSTimer* timer_ = nil;
  std::function<void()> done_;
  NSPoint location_ = NSZeroPoint;
  int step_ = 0;
};

}  // namespace aud_vst3

#endif  // __OBJC__

#endif  // AUD_VST3_DRIVER_HPP
