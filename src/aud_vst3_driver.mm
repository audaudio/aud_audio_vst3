// @license
// Copyright (c) Audanika. All Rights Reserved.
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

#include "aud_vst3_driver.hpp"

#include "aud_vst3_layout.hpp"

namespace aud_vst3 {

namespace {

// The steps of waiting between the preset value and the mouse down.
constexpr int kSettleSteps = 30;

}  // namespace

SyntheticDrag::~SyntheticDrag() { stop(); }

void SyntheticDrag::start(NSView* view, ViewDelegate* delegate,
                          const std::function<void()>& prepare,
                          std::function<void()> done) {
  stop();
  view_ = view;
  delegate_ = delegate;
  done_ = std::move(done);
  location_ = NSMakePoint(knobLeft(kTestKnob) + kKnobSize / 2,
                          kKnobTop + kKnobSize / 2);
  step_ = -kSettleSteps;
  if (prepare) prepare();
  SyntheticDrag* self = this;
  timer_ = [NSTimer timerWithTimeInterval:kTestPeriod
                                  repeats:YES
                                    block:^(NSTimer*) {
                                      self->step();
                                    }];
  [[NSRunLoop mainRunLoop] addTimer:timer_ forMode:NSRunLoopCommonModes];
}

void SyntheticDrag::stop() {
  [timer_ invalidate];
  timer_ = nil;
}

NSEvent* SyntheticDrag::event(NSEventType type, NSPoint location) {
  NSView* view = view_;
  const NSPoint inWindow = [view convertPoint:location toView:nil];
  return [NSEvent mouseEventWithType:type
                            location:inWindow
                       modifierFlags:0
                           timestamp:[NSProcessInfo processInfo].systemUptime
                        windowNumber:view.window.windowNumber
                             context:nil
                         eventNumber:0
                          clickCount:1
                            pressure:type == NSEventTypeLeftMouseUp ? 0 : 1];
}

void SyntheticDrag::step() {
  NSView* view = view_;
  if (view == nil || view.window == nil || delegate_ == nullptr) {
    stop();
    return;
  }
  const int index = step_++;
  if (index < 0) return;
  if (index == 0) {
    delegate_->mouseEvent(view, event(NSEventTypeLeftMouseDown, location_));
    return;
  }
  if (index <= kTestSteps) {
    // Up for the first half (smaller y), down for the second.
    location_.y += index <= kTestSteps / 2 ? -kTestStepPoints : kTestStepPoints;
    delegate_->mouseEvent(view, event(NSEventTypeLeftMouseDragged, location_));
    return;
  }
  delegate_->mouseEvent(view, event(NSEventTypeLeftMouseUp, location_));
  stop();
  if (done_) done_();
}

}  // namespace aud_vst3
