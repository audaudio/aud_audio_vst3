// @license
// Copyright (c) Audanika. All Rights Reserved.
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

// Variant C of the spike (ticket 24): the editor as a native AppKit view.
// The knobs follow the ArcKnob of aud_audio_ui_controls - an arc from 135°
// to 405° with the gap at the bottom - and are drawn with Core Graphics.
// The baseline for latency, memory and opening time.

#import <Cocoa/Cocoa.h>

#include <cmath>
#include <string>
#include <vector>

#include "aud_vst3_driver.hpp"
#include "aud_vst3_layout.hpp"
#include "aud_vst3_objc.hpp"
#include "aud_vst3_plugin.hpp"
#include "public.sdk/source/common/pluginview.h"

namespace aud_vst3 {

using namespace Steinberg;

namespace {

int64_t stampOf(NSEvent* event) {
  return static_cast<int64_t>(event.timestamp * 1e9);
}

}  // namespace

class NativeView : public CPluginView, public ViewDelegate, public ParamObserver {
 public:
  explicit NativeView(Plugin* plugin)
      : CPluginView(nullptr), plugin_(plugin) {
    ViewRect size(0, 0, static_cast<int32>(kEditorWidth),
                  static_cast<int32>(kEditorHeight));
    setRect(size);
    for (int i = 0; i < kKnobCount; ++i) {
      Knob knob;
      knob.label = kKnobs[i].label;
      for (const EngineParam& param : plugin_->params()) {
        if (param.nodeId == kKnobs[i].nodeId &&
            param.paramId == kKnobs[i].paramId) {
          knob.id = param.id;
        }
      }
      knob.value = plugin_->normalized(knob.id);
      knobs_.push_back(knob);
    }
    // The view holds the plugin, as the SDK's EditorView holds its
    // controller: a host may release the plugin before the view.
    plugin_->addRef();
    plugin_->addObserver(this);
  }

  ~NativeView() override {
    plugin_->removeObserver(this);
    teardown();
    plugin_->release();
  }

  tresult PLUGIN_API isPlatformTypeSupported(FIDString type) SMTG_OVERRIDE {
    return std::strcmp(type, kPlatformTypeNSView) == 0 ? kResultTrue
                                                        : kResultFalse;
  }

  tresult PLUGIN_API attached(void* parent, FIDString type) SMTG_OVERRIDE {
    const int64_t start = nowNs();
    if (isPlatformTypeSupported(type) != kResultTrue) return kResultFalse;
    NSView* parentView = (__bridge NSView*)parent;
    view_ = makeView(this, NSMakeRect(0, 0, rect.getWidth(), rect.getHeight()));
    [parentView addSubview:view_];
    NativeView* self = this;
    meterTimer_ = [NSTimer timerWithTimeInterval:1.0 / 30
                                         repeats:YES
                                           block:^(NSTimer*) {
                                             self->meterTick();
                                           }];
    [[NSRunLoop mainRunLoop] addTimer:meterTimer_ forMode:NSRunLoopCommonModes];
    openStamp_ = start;
    firstDraw_ = true;
    plugin_->probe().write(
        "attached", "\"variant\":\"C\",\"class\":\"" +
                        std::string(viewClassName()) + "\",\"implFlavor\":" +
                        std::to_string(implementationFlavor(view_)));
    return CPluginView::attached(parent, type);
  }

  tresult PLUGIN_API removed() SMTG_OVERRIDE {
    const int64_t start = nowNs();
    teardown();
    plugin_->probe().write("removed",
                           "\"ns\":" + std::to_string(nowNs() - start));
    return CPluginView::removed();
  }

  tresult PLUGIN_API onSize(ViewRect* newSize) SMTG_OVERRIDE {
    if (newSize != nullptr && view_ != nil) {
      [view_ setFrame:NSMakeRect(0, 0, newSize->getWidth(),
                                 newSize->getHeight())];
      [view_ setNeedsDisplay:YES];
    }
    return CPluginView::onSize(newSize);
  }

  tresult PLUGIN_API canResize() SMTG_OVERRIDE { return kResultTrue; }

  tresult PLUGIN_API checkSizeConstraint(ViewRect* r) SMTG_OVERRIDE {
    if (r == nullptr) return kInvalidArgument;
    if (r->getWidth() < kEditorMinWidth) {
      r->right = r->left + static_cast<int32>(kEditorMinWidth);
    }
    if (r->getHeight() < kEditorMinHeight) {
      r->bottom = r->top + static_cast<int32>(kEditorMinHeight);
    }
    return kResultTrue;
  }

  // ViewDelegate

  void drawRect(NSView* view, NSRect) override {
    CGContextRef ctx = [NSGraphicsContext currentContext].CGContext;
    const NSRect bounds = view.bounds;
    CGContextSetRGBFillColor(ctx, 0.11, 0.12, 0.14, 1);
    CGContextFillRect(ctx, bounds);
    NSDictionary* labelAttrs = @{
      NSFontAttributeName : [NSFont systemFontOfSize:12],
      NSForegroundColorAttributeName : [NSColor colorWithWhite:0.8 alpha:1]
    };
    NSDictionary* valueAttrs = @{
      NSFontAttributeName : [NSFont monospacedDigitSystemFontOfSize:11
                                                             weight:NSFontWeightRegular],
      NSForegroundColorAttributeName : [NSColor colorWithWhite:0.6 alpha:1]
    };
    for (int i = 0; i < kKnobCount; ++i) {
      Knob& knob = knobs_[i];
      const double cx = knobLeft(i) + kKnobSize / 2;
      const double cy = kKnobTop + kKnobSize / 2;
      const double radius = kKnobSize / 2 - 6;
      const double start = M_PI * 0.75;
      const double sweep = M_PI * 1.5;
      CGContextSetLineCap(ctx, kCGLineCapRound);
      CGContextSetLineWidth(ctx, 6);
      CGContextSetRGBStrokeColor(ctx, 0.25, 0.27, 0.3, 1);
      CGContextAddArc(ctx, cx, cy, radius, start, start + sweep, 0);
      CGContextStrokePath(ctx);
      CGContextSetRGBStrokeColor(ctx, 0.36, 0.67, 0.98, 1);
      CGContextAddArc(ctx, cx, cy, radius, start,
                      start + sweep * std::max(0.001, knob.value), 0);
      CGContextStrokePath(ctx);
      NSString* label = [NSString stringWithUTF8String:knob.label.c_str()];
      const NSSize labelSize = [label sizeWithAttributes:labelAttrs];
      [label drawAtPoint:NSMakePoint(cx - labelSize.width / 2,
                                     kKnobTop + kKnobSize + 8)
          withAttributes:labelAttrs];
      Vst::String128 text{};
      plugin_->getParamStringByValue(knob.id, knob.value, text);
      NSString* value = [NSString
          stringWithCharacters:reinterpret_cast<const unichar*>(text)
                        length:std::char_traits<char16_t>::length(
                                   reinterpret_cast<const char16_t*>(text))];
      const NSSize valueSize = [value sizeWithAttributes:valueAttrs];
      [value drawAtPoint:NSMakePoint(cx - valueSize.width / 2, cy - 7)
          withAttributes:valueAttrs];
      if (knob.pendingDrawn) {
        knob.pendingDrawn = false;
        plugin_->probe().write("drawn",
                               "\"id\":" + std::to_string(knob.id) +
                                   ",\"value\":" + probeNumber(knob.value));
      }
    }
    Engine* engine = plugin_->engine();
    const EngineMeter meter = engine != nullptr ? engine->meter() : EngineMeter{};
    const double height = bounds.size.height - 2 * kKnobTop + 40;
    const double level = std::min(1.0, static_cast<double>(meter.peak));
    CGContextSetRGBFillColor(ctx, 0.2, 0.22, 0.25, 1);
    CGContextFillRect(ctx, CGRectMake(kMeterLeft, kKnobTop - 20, kMeterWidth,
                                      height));
    CGContextSetRGBFillColor(ctx, 0.35, 0.85, 0.45, 1);
    CGContextFillRect(ctx, CGRectMake(kMeterLeft,
                                      kKnobTop - 20 + height * (1 - level),
                                      kMeterWidth, height * level));
    if (firstDraw_) {
      firstDraw_ = false;
      plugin_->probe().write(
          "firstFrame", "\"variant\":\"C\",\"ns\":" +
                            std::to_string(nowNs() - openStamp_));
    }
  }

  void mouseEvent(NSView* view, NSEvent* event) override {
    const NSPoint p = [view convertPoint:event.locationInWindow fromView:nil];
    switch (event.type) {
      case NSEventTypeLeftMouseDown: {
        active_ = hit(p);
        if (active_ < 0) return;
        Knob& knob = knobs_[active_];
        if (event.clickCount == 2) {
          const Vst::Parameter* parameter = plugin_->getParameterObject(knob.id);
          plugin_->editBegin(knob.id, this);
          knob.value = parameter->getInfo().defaultNormalizedValue;
          plugin_->edit(knob.id, knob.value, stampOf(event), this);
          plugin_->editEnd(knob.id, this);
          active_ = -1;
          [view setNeedsDisplay:YES];
          return;
        }
        dragStartY_ = p.y;
        dragStartValue_ = knob.value;
        plugin_->editBegin(knob.id, this);
        return;
      }
      case NSEventTypeLeftMouseDragged: {
        if (active_ < 0) return;
        Knob& knob = knobs_[active_];
        const double scale =
            (event.modifierFlags & NSEventModifierFlagShift) != 0 ? 5 : 1;
        const double value =
            std::min(1.0, std::max(0.0, dragStartValue_ -
                                            (p.y - dragStartY_) /
                                                (kDragRange * scale)));
        if (value == knob.value) return;
        knob.value = value;
        plugin_->edit(knob.id, value, stampOf(event), this);
        [view setNeedsDisplay:YES];
        return;
      }
      case NSEventTypeLeftMouseUp:
        if (active_ >= 0) plugin_->editEnd(knobs_[active_].id, this);
        active_ = -1;
        return;
      default:
        return;
    }
  }

  void scrollEvent(NSView* view, NSEvent* event) override {
    const NSPoint p = [view convertPoint:event.locationInWindow fromView:nil];
    const int index = hit(p);
    if (index < 0) return;
    Knob& knob = knobs_[index];
    const double delta = event.hasPreciseScrollingDeltas
                             ? event.scrollingDeltaY / kDragRange
                             : event.scrollingDeltaY / 50;
    const double value = std::min(1.0, std::max(0.0, knob.value + delta));
    if (value == knob.value) return;
    plugin_->editBegin(knob.id, this);
    knob.value = value;
    plugin_->edit(knob.id, value, stampOf(event), this);
    plugin_->editEnd(knob.id, this);
    [view setNeedsDisplay:YES];
  }

  void keyEvent(NSView*, NSEvent* event) override {
    if (event.type == NSEventTypeKeyDown &&
        [event.charactersIgnoringModifiers isEqualToString:@"t"]) {
      testRequested();
    }
  }

  // ParamObserver

  void paramChanged(uint32_t id, double normalized) override {
    for (Knob& knob : knobs_) {
      if (knob.id != id) continue;
      knob.value = normalized;
      knob.pendingDrawn = true;
      [view_ setNeedsDisplay:YES];
    }
  }

  void testRequested() override {
    if (view_ == nil || drag_.running()) return;
    const uint32_t id = knobs_[kTestKnob].id;
    plugin_->probe().write("testStart", "\"variant\":\"C\",\"id\":" +
                                            std::to_string(id));
    NativeView* self = this;
    drag_.start(
        view_, this,
        [self, id] {
          self->plugin_->editBegin(id, self);
          self->knobs_[kTestKnob].value = kTestStartValue;
          self->plugin_->edit(id, kTestStartValue, nowNs(), self);
          self->plugin_->editEnd(id, self);
          [self->view_ setNeedsDisplay:YES];
        },
        [self] { self->plugin_->probe().write("testEnd", "\"variant\":\"C\""); });
  }

  OBJ_METHODS(NativeView, CPluginView)
  REFCOUNT_METHODS(CPluginView)

 private:
  struct Knob {
    uint32_t id = 0;
    std::string label;
    double value = 0;
    bool pendingDrawn = false;
  };

  int hit(NSPoint p) const {
    for (int i = 0; i < kKnobCount; ++i) {
      if (p.x >= knobLeft(i) && p.x <= knobLeft(i) + kKnobSize &&
          p.y >= kKnobTop && p.y <= kKnobTop + kKnobSize) {
        return i;
      }
    }
    return -1;
  }

  void meterTick() {
    Engine* engine = plugin_->engine();
    if (engine == nullptr || view_ == nil) return;
    const EngineMeter meter = engine->meter();
    if (meter.peak != lastPeak_) {
      lastPeak_ = meter.peak;
      [view_ setNeedsDisplayInRect:NSMakeRect(kMeterLeft, 0, kMeterWidth,
                                              view_.bounds.size.height)];
    }
  }

  void teardown() {
    drag_.stop();
    [meterTimer_ invalidate];
    meterTimer_ = nil;
    // A view closed mid-drag leaves no gesture open in the host.
    plugin_->endEdits(this);
    active_ = -1;
    if (view_ != nil) {
      clearDelegate(view_);
      [view_ removeFromSuperview];
      view_ = nil;
    }
  }

  Plugin* plugin_;
  NSView* view_ = nil;
  NSTimer* meterTimer_ = nil;
  std::vector<Knob> knobs_;
  int active_ = -1;
  double dragStartY_ = 0;
  double dragStartValue_ = 0;
  float lastPeak_ = -1;
  int64_t openStamp_ = 0;
  bool firstDraw_ = false;
  SyntheticDrag drag_;
};

IPlugView* createEditorView(Plugin* plugin) { return new NativeView(plugin); }

}  // namespace aud_vst3
