// @license
// Copyright (c) Audanika. All Rights Reserved.
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

// The layout every editor of the spike shares (ticket 24): the native view
// (C), the Flutter editor (A, B; editor/lib/src/aud_editor_layout.dart) and
// the synthetic drag of the latency measurement, which needs the knob at
// the same place in every variant. Points, origin top left.

#ifndef AUD_VST3_LAYOUT_HPP
#define AUD_VST3_LAYOUT_HPP

#include <cstdint>

namespace aud_vst3 {

// #############################################################################
// The size of the editor when it opens, and the smallest it resizes to.
constexpr double kEditorWidth = 620;
constexpr double kEditorHeight = 220;
constexpr double kEditorMinWidth = 400;
constexpr double kEditorMinHeight = 160;

// #############################################################################
// The knobs: their count and size, the left edge of the first, the
// distance from the left edge of one to the next, and the top edge.
constexpr int kKnobCount = 5;
constexpr double kKnobSize = 80;
constexpr double kKnobLeft = 20;
constexpr double kKnobSpacing = 110;
constexpr double kKnobTop = 60;

// #############################################################################
// A knob: the parameter it shows and its label.
struct KnobSpec {
  // ...........................................................................
  // The node id and the parameter id in the graph document.
  const char* nodeId;
  const char* paramId;

  // ...........................................................................
  // The label under the knob.
  const char* label;
};

// #############################################################################
// The knobs from left to right.
constexpr KnobSpec kKnobs[kKnobCount] = {
    {"osc", "frequency", "Frequency"}, {"osc", "amplitude", "Level"},
    {"filter", "cutoff", "Cutoff"},    {"filter", "resonance", "Resonance"},
    {"out", "master", "Master"},
};

// #############################################################################
// The knob the synthetic drag moves: the cutoff.
constexpr int kTestKnob = 2;

// #############################################################################
// The drag: points per full range, so a value step of 0.001 is 0.2 points.
constexpr double kDragRange = 200;

// #############################################################################
// The synthetic drag: steps, the step in points, the period in seconds and
// the value the knob starts from.
constexpr int kTestSteps = 1000;
constexpr double kTestStepPoints = 0.2;
constexpr double kTestPeriod = 1.0 / 60.0;
constexpr double kTestStartValue = 0.25;

// #############################################################################
// The meter: its left edge and width, and how often an editor takes its
// value, in seconds.
constexpr double kMeterLeft = 575;
constexpr double kMeterWidth = 20;
constexpr double kMeterPeriod = 1.0 / 30;

// #############################################################################
// An opaque color of the editors.
struct EditorColor {
  // ...........................................................................
  // The red, green and blue components from 0 to 1.
  double red;
  double green;
  double blue;
};

// #############################################################################
// The background of every editor.
constexpr EditorColor kEditorBackground = {0.11, 0.12, 0.14};

// #############################################################################
// The left edge of knob `index`.
inline double knobLeft(int index) { return kKnobLeft + index * kKnobSpacing; }

}  // namespace aud_vst3

#endif  // AUD_VST3_LAYOUT_HPP
