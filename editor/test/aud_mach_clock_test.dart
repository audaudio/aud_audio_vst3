// @license
// Copyright (c) Audanika. All Rights Reserved.
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'package:aud_audio_vst3_editor/src/aud_mach_clock.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('AudMachClock', () {
    group('nowNs()', () {
      test('is positive and never runs backwards', () {
        final readings = [for (var i = 0; i < 1000; ++i) AudMachClock.nowNs()];
        expect(readings.first, greaterThan(0));
        expect(readings, [...readings]..sort());
      });

      test('counts nanoseconds', () async {
        final first = AudMachClock.nowNs();
        final stopwatch = Stopwatch()..start();
        await Future<void>.delayed(const Duration(milliseconds: 20));
        final elapsed = AudMachClock.nowNs() - first;
        stopwatch.stop();
        expect(elapsed, greaterThanOrEqualTo(20 * 1000 * 1000));
        expect(elapsed, closeTo(stopwatch.elapsedMicroseconds * 1000, 5e6));
      });
    });
  });
}
