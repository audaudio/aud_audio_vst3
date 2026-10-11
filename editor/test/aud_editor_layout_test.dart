// @license
// Copyright (c) Audanika. All Rights Reserved.
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:io';

import 'package:aud_audio_vst3_editor/src/aud_editor_layout.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('AudEditorLayout', () {
    // The layout of the native views, which the editor's mirrors.
    String header() => File('../src/aud_vst3_layout.hpp').readAsStringSync();

    // The value of the native constant [name].
    double native(String name) => double.parse(
      RegExp('constexpr double $name = ([0-9.]+);').firstMatch(header())![1]!,
    );

    test('has the sizes of src/aud_vst3_layout.hpp', () {
      expect(
        [
          AudEditorLayout.width,
          AudEditorLayout.height,
          AudEditorLayout.knobSize,
          AudEditorLayout.knobLeft,
          AudEditorLayout.knobSpacing,
          AudEditorLayout.knobTop,
          AudEditorLayout.meterLeft,
          AudEditorLayout.meterWidth,
        ],
        [
          for (final name in [
            'kEditorWidth',
            'kEditorHeight',
            'kKnobSize',
            'kKnobLeft',
            'kKnobSpacing',
            'kKnobTop',
            'kMeterLeft',
            'kMeterWidth',
          ])
            native(name),
        ],
      );
    });

    test('has the knobs of src/aud_vst3_layout.hpp', () {
      final knob = RegExp(r'\{"(\w+)", "(\w+)", "([^"]+)"\}');
      expect(AudEditorLayout.knobs, [
        for (final match in knob.allMatches(header()))
          (match[1]!, match[2]!, match[3]!),
      ]);
    });

    group('knobLeftOf(index)', () {
      for (final (index, left) in [(0, 20.0), (1, 130.0), (4, 460.0)]) {
        test('puts knob $index at $left', () {
          expect(AudEditorLayout.knobLeftOf(index), left);
        });
      }
    });
  });
}
