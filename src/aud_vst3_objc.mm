// @license
// Copyright (c) Audanika. All Rights Reserved.
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

#include "aud_vst3_objc.hpp"

#import <objc/message.h>
#import <objc/runtime.h>

#include <cstdio>
#include <cstdlib>
#include <string>

#include "aud_vst3_config.hpp"

namespace aud_vst3 {

namespace {

const char* const kDelegateIvar = "audDelegate";

std::string& className() {
  static std::string name;
  return name;
}

ViewDelegate* delegateOf(id self) {
  Ivar ivar = class_getInstanceVariable(object_getClass(self), kDelegateIvar);
  if (ivar == nullptr) return nullptr;
  auto* slot = reinterpret_cast<ViewDelegate**>(
      reinterpret_cast<char*>((__bridge void*)self) + ivar_getOffset(ivar));
  return *slot;
}

void setDelegateOf(id self, ViewDelegate* delegate) {
  Ivar ivar = class_getInstanceVariable(object_getClass(self), kDelegateIvar);
  if (ivar == nullptr) return;
  auto* slot = reinterpret_cast<ViewDelegate**>(
      reinterpret_cast<char*>((__bridge void*)self) + ivar_getOffset(ivar));
  *slot = delegate;
}

BOOL yes(id, SEL) { return YES; }
BOOL yesForEvent(id, SEL, NSEvent*) { return YES; }

int flavor(id, SEL) { return AUD_VST3_FLAVOR; }

void drawRect(id self, SEL, NSRect dirty) {
  if (ViewDelegate* d = delegateOf(self)) d->drawRect(self, dirty);
}

void mouse(id self, SEL, NSEvent* event) {
  if (ViewDelegate* d = delegateOf(self)) d->mouseEvent(self, event);
}

void scroll(id self, SEL, NSEvent* event) {
  if (ViewDelegate* d = delegateOf(self)) d->scrollEvent(self, event);
}

// The delegate sees every key, which then goes on along the responder
// chain: the host's shortcuts (Space for the transport) keep working while
// the plugin's view has the focus. An editor that takes text must claim its
// keys instead (S18, open question 3).
void key(id self, SEL cmd, NSEvent* event) {
  if (ViewDelegate* d = delegateOf(self)) d->keyEvent(self, event);
  struct objc_super parent = {self, [NSView class]};
  reinterpret_cast<void (*)(struct objc_super*, SEL, NSEvent*)>(objc_msgSendSuper)(
      &parent, cmd, event);
}

void cursor(id self, SEL, NSEvent* event) {
  if (ViewDelegate* d = delegateOf(self)) d->cursorUpdate(self, event);
}

BOOL becomeFirstResponder(id self, SEL) {
  if (ViewDelegate* d = delegateOf(self)) d->focusChanged(self, true);
  return YES;
}

BOOL resignFirstResponder(id self, SEL) {
  if (ViewDelegate* d = delegateOf(self)) d->focusChanged(self, false);
  return YES;
}

void viewDidMoveToWindow(id self, SEL) {
  if (ViewDelegate* d = delegateOf(self)) d->windowChanged(self);
}

void updateTrackingAreas(id self, SEL cmd) {
  NSView* view = self;
  for (NSTrackingArea* area in [view.trackingAreas copy]) {
    if (area.owner == view) [view removeTrackingArea:area];
  }
  [view addTrackingArea:[[NSTrackingArea alloc]
                            initWithRect:NSZeroRect
                                 options:NSTrackingMouseMoved |
                                         NSTrackingMouseEnteredAndExited |
                                         NSTrackingCursorUpdate |
                                         NSTrackingActiveAlways |
                                         NSTrackingInVisibleRect
                                   owner:view
                                userInfo:nil]];
  struct objc_super parent = {view, [NSView class]};
  reinterpret_cast<void (*)(struct objc_super*, SEL)>(objc_msgSendSuper)(&parent,
                                                                       cmd);
}

std::string randomName() {
  char suffix[24];
  std::snprintf(suffix, sizeof(suffix), "%08x%08x", arc4random(),
                arc4random());
  return std::string("AudVst3View_") + suffix;
}

Class createClass() {
#ifdef AUD_VST3_NO_HYGIENE
  className() = "AudVst3SpikeView";
  if (Class existing = objc_lookUpClass(className().c_str())) return existing;
#else
  do {
    className() = randomName();
  } while (objc_lookUpClass(className().c_str()) != nil);
#endif
  Class cls = objc_allocateClassPair([NSView class], className().c_str(), 0);
  class_addIvar(cls, kDelegateIvar, sizeof(void*), alignof(void*) == 8 ? 3 : 2,
                "^v");
  class_addMethod(cls, @selector(isFlipped), (IMP)yes, "c@:");
  class_addMethod(cls, @selector(acceptsFirstResponder), (IMP)yes, "c@:");
  class_addMethod(cls, @selector(acceptsFirstMouse:), (IMP)yesForEvent, "c@:@");
  class_addMethod(cls, @selector(audFlavor), (IMP)flavor, "i@:");
  class_addMethod(cls, @selector(drawRect:), (IMP)drawRect,
                  "v@:{CGRect={CGPoint=dd}{CGSize=dd}}");
  for (SEL selector :
       {@selector(mouseDown:), @selector(mouseUp:), @selector(mouseDragged:),
        @selector(rightMouseDown:), @selector(rightMouseUp:),
        @selector(rightMouseDragged:), @selector(otherMouseDown:),
        @selector(otherMouseUp:), @selector(otherMouseDragged:),
        @selector(mouseMoved:), @selector(mouseEntered:),
        @selector(mouseExited:)}) {
    class_addMethod(cls, selector, (IMP)mouse, "v@:@");
  }
  class_addMethod(cls, @selector(scrollWheel:), (IMP)scroll, "v@:@");
  for (SEL selector :
       {@selector(keyDown:), @selector(keyUp:), @selector(flagsChanged:)}) {
    class_addMethod(cls, selector, (IMP)key, "v@:@");
  }
  class_addMethod(cls, @selector(cursorUpdate:), (IMP)cursor, "v@:@");
  class_addMethod(cls, @selector(becomeFirstResponder),
                  (IMP)becomeFirstResponder, "c@:");
  class_addMethod(cls, @selector(resignFirstResponder),
                  (IMP)resignFirstResponder, "c@:");
  class_addMethod(cls, @selector(viewDidMoveToWindow),
                  (IMP)viewDidMoveToWindow, "v@:");
  class_addMethod(cls, @selector(updateTrackingAreas),
                  (IMP)updateTrackingAreas, "v@:");
  objc_registerClassPair(cls);
  return cls;
}

}  // namespace

Class viewClass() {
  static Class cls = createClass();
  return cls;
}

const char* viewClassName() {
  viewClass();
  return className().c_str();
}

NSView* makeView(ViewDelegate* delegate, NSRect frame) {
  NSView* view = [[viewClass() alloc] initWithFrame:frame];
  setDelegateOf(view, delegate);
  return view;
}

void clearDelegate(NSView* view) {
  if (view != nil) setDelegateOf(view, nullptr);
}

int implementationFlavor(NSView* view) {
  if (![view respondsToSelector:@selector(audFlavor)]) return 0;
  return reinterpret_cast<int (*)(id, SEL)>(objc_msgSend)(view,
                                                         @selector(audFlavor));
}

}  // namespace aud_vst3
