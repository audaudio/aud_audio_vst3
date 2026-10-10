// @license
// Copyright (c) Audanika. All Rights Reserved.
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

// The NSView class of the spike's editors, created at run time (ticket 24).
//
// Objective-C has one class namespace per process. Two plugins that both
// define a class of the same name share one of the two implementations -
// "which one is undefined" - so an aud_audio-based plugin creates its view
// class at run time under a name with a random suffix, as JUCE does. The
// control build (AUD_VST3_NO_HYGIENE) registers a fixed name and reuses a
// class of that name that another image registered first.
//
// The class forwards its events to a ViewDelegate, a C++ object whose
// pointer it keeps in an instance variable.

#ifndef AUD_VST3_OBJC_HPP
#define AUD_VST3_OBJC_HPP

#ifdef __OBJC__
#import <Cocoa/Cocoa.h>

namespace aud_vst3 {

// What the view class forwards. Called on the host's UI thread.
class ViewDelegate {
 public:
  virtual ~ViewDelegate() = default;
  virtual void drawRect(NSView* view, NSRect dirty) {}
  virtual void mouseEvent(NSView* view, NSEvent* event) {}
  virtual void scrollEvent(NSView* view, NSEvent* event) {}
  virtual void keyEvent(NSView* view, NSEvent* event) {}
  virtual void focusChanged(NSView* view, bool focused) {}
  virtual void windowChanged(NSView* view) {}
  virtual void cursorUpdate(NSView* view, NSEvent* event) {}
};

// The view class of this image; created once.
Class viewClass();

// The name of the view class of this image.
const char* viewClassName();

// Creates a view of the class for `delegate`.
NSView* makeView(ViewDelegate* delegate, NSRect frame);

// Detaches the delegate before the C++ object goes.
void clearDelegate(NSView* view);

// The flavor of the image whose code implements the class methods: the
// class of another image answers with that image's flavor.
int implementationFlavor(NSView* view);

}  // namespace aud_vst3

#endif  // __OBJC__

#endif  // AUD_VST3_OBJC_HPP
