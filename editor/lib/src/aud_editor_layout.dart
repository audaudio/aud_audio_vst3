// @license
// Copyright (c) Audanika. All Rights Reserved.
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

// #############################################################################
/// The layout every editor of the spike shares; mirrors
/// src/aud_vst3_layout.hpp of aud_audio_vst3, so that the synthetic drag of
/// the latency measurement hits the same knob in every variant. Points,
/// origin top left.
abstract final class AudEditorLayout {
  // ...........................................................................
  /// The editor's width.
  static const double width = 620;

  // ...........................................................................
  /// The editor's height.
  static const double height = 220;

  // ...........................................................................
  /// The diameter of a knob.
  static const double knobSize = 80;

  // ...........................................................................
  /// The left edge of the first knob.
  static const double knobLeft = 20;

  // ...........................................................................
  /// The distance between the left edges of two knobs.
  static const double knobSpacing = 110;

  // ...........................................................................
  /// The top edge of the knobs.
  static const double knobTop = 60;

  // ...........................................................................
  /// The left edge of the meter.
  static const double meterLeft = 575;

  // ...........................................................................
  /// The width of the meter.
  static const double meterWidth = 20;

  // ...........................................................................
  /// The background.
  static const int background = 0xFF1C1F24;

  // ...........................................................................
  /// The knobs: node id, parameter id, label.
  static const List<(String, String, String)> knobs = [
    ('osc', 'frequency', 'Frequency'),
    ('osc', 'amplitude', 'Level'),
    ('filter', 'cutoff', 'Cutoff'),
    ('filter', 'resonance', 'Resonance'),
    ('out', 'master', 'Master'),
  ];

  // ...........................................................................
  /// The left edge of knob [index].
  static double knobLeftOf(int index) => knobLeft + index * knobSpacing;
}
