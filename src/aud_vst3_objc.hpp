// @license
// Copyright (c) Audanika. All Rights Reserved.
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

// The NSView class of the plugin's editor view, created at run time
// (tickets 24 and 37).
//
// Objective-C has one class namespace per process. Two plugins that both
// define a class of the same name share one of the two implementations -
// "which one is undefined" - so an aud_audio-based plugin creates its view
// class at run time under a name with a random suffix, as JUCE does
// (plugin-004).
//
// The class forwards its events to a ViewDelegate, a C++ object whose
// pointer it keeps in an instance variable.

#ifndef AUD_VST3_OBJC_HPP
#define AUD_VST3_OBJC_HPP

#ifdef __OBJC__
#import <Cocoa/Cocoa.h>

#include <cstdint>

namespace aud_vst3 {

// #############################################################################
// What the view class forwards. Called on the host's UI thread.
class ViewDelegate {
 public:
  // ...........................................................................
  // Destroys the delegate; clearDelegate() detaches it from its view first.
  virtual ~ViewDelegate() = default;

  // ...........................................................................
  // Draws the part `dirty` of `view`.
  virtual void drawRect(NSView* view, NSRect dirty) {}

  // ...........................................................................
  // Takes a mouse button, a drag or a move in `view`, or the mouse entering
  // or leaving it.
  virtual void mouseEvent(NSView* view, NSEvent* event) {}

  // ...........................................................................
  // Takes a scroll of the wheel or the trackpad over `view`.
  virtual void scrollEvent(NSView* view, NSEvent* event) {}

  // ...........................................................................
  // Takes a key or a change of the modifiers in `view`; the event goes on
  // along the responder chain afterwards.
  virtual void keyEvent(NSView* view, NSEvent* event) {}

  // ...........................................................................
  // Learns that `view` took (true) or lost the keyboard focus.
  virtual void focusChanged(NSView* view, bool focused) {}

  // ...........................................................................
  // Learns that `view` moved into another window or out of its window.
  virtual void windowChanged(NSView* view) {}

  // ...........................................................................
  // Sets the cursor over `view`.
  virtual void cursorUpdate(NSView* view, NSEvent* event) {}
};

// #############################################################################
// The view class of this image; created once.
Class viewClass();

// #############################################################################
// The name of the view class of this image.
const char* viewClassName();

// #############################################################################
// Creates a view of the class for `delegate`.
NSView* makeView(ViewDelegate* delegate, NSRect frame);

// #############################################################################
// Detaches the delegate before the C++ object goes.
void clearDelegate(NSView* view);

// #############################################################################
// The time of `event` in nanoseconds since the system started.
int64_t stampOf(NSEvent* event);

}  // namespace aud_vst3

#endif  // __OBJC__

#endif  // AUD_VST3_OBJC_HPP
