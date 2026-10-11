// @license
// Copyright (c) Audanika. All Rights Reserved.
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'package:aud_audio_vst3/aud_audio_vst3.dart';
import 'package:aud_audio_vst3_editor/src/aud_editor_runner.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('AudEditorRunner', () {
    // The channel macos/Runner/AudEditorViews.swift listens on.
    const channel = MethodChannel('aud_vst3_editor/runner');
    const runner = AudEditorRunner();
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    late List<MethodCall> calls;
    late Object? answer;

    setUp(() {
      calls = [];
      answer = null;
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return answer;
      });
    });

    tearDown(() => messenger.setMockMethodCallHandler(channel, null));

    // What the native runner received: method and arguments of each call.
    List<List<Object?>> received() => [
      for (final call in calls) [call.method, call.arguments],
    ];

    group('addView(instance, welcome)', () {
      const welcome = AudShellWelcome(
        instance: 2,
        name: 'spike',
        params: [],
        width: 620,
        height: 220,
        scale: 2,
      );

      for (final viewId in [7, -1]) {
        test('asks for a view of the editor size, gets $viewId', () async {
          answer = viewId;
          expect(await runner.addView(2, welcome), viewId);
          expect(received(), [
            [
              'addView',
              {'instance': 2, 'width': 620, 'height': 220},
            ],
          ]);
        });
      }
    });

    group('place(place)', () {
      test('sends frame, scale, window and visibility', () async {
        await runner.place(
          const AudShellPlace(
            instance: 3,
            x: 10,
            y: 20,
            width: 700,
            height: 300,
            scale: 2,
            window: 5,
            visible: false,
          ),
        );
        expect(received(), [
          [
            'place',
            {
              'instance': 3,
              'x': 10,
              'y': 20,
              'width': 700,
              'height': 300,
              'scale': 2,
              'window': 5,
              'visible': false,
            },
          ],
        ]);
      });
    });

    group('visible(instance, visible)', () {
      for (final visible in [true, false]) {
        test('sends visible $visible', () async {
          await runner.visible(4, visible);
          expect(received(), [
            [
              'visible',
              {'instance': 4, 'visible': visible},
            ],
          ]);
        });
      }
    });

    group('removeView(instance)', () {
      test('drops the view of the instance', () async {
        await runner.removeView(4);
        expect(received(), [
          [
            'removeView',
            {'instance': 4},
          ],
        ]);
      });
    });

    group('quit()', () {
      test('quits the editor process', () async {
        await runner.quit();
        expect(received(), [
          ['quit', null],
        ]);
      });
    });
  });
}
