// @license
// Copyright (c) Audanika. All Rights Reserved.
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'package:aud_audio_vst3/aud_audio_vst3.dart';
import 'package:aud_audio_vst3_editor/src/aud_editor_instance.dart';
import 'package:aud_audio_vst3_editor/src/aud_input_injector.dart';
import 'package:aud_audio_vst3_editor/src/aud_shell_param_sink.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('AudEditorInstance', () {
    const welcome = AudShellWelcome(
      instance: 2,
      name: 'spike',
      params: [],
      width: 620,
      height: 220,
      scale: 2,
    );
    late AudShellParamSink sink;
    late AudInputInjector injector;
    late AudEditorInstance instance;

    setUp(() {
      sink = AudShellParamSink(
        send: (_) {},
        params: const [],
        inputStamp: () => 0,
        instance: 2,
      );
      injector = AudInputInjector(dispatch: (_) {}, viewId: 5, instance: 2);
      instance = AudEditorInstance(
        instance: 2,
        viewId: 5,
        welcome: welcome,
        sink: sink,
        injector: injector,
      );
    });

    group('AudEditorInstance(...)', () {
      test('keeps view, parameters, sink and input, the meter at 0', () {
        expect(
          [
            instance.instance,
            instance.viewId,
            instance.welcome,
            instance.sink,
            instance.injector,
            instance.meter.value,
          ],
          [2, 5, welcome, sink, injector, 0],
        );
      });
    });

    group('dispose()', () {
      test('releases the meter and closes the sink', () async {
        final closed = sink.changes.isEmpty;
        await instance.dispose();
        expect(await closed, isTrue);
        expect(
          () => instance.meter.addListener(() {}),
          throwsA(
            isA<FlutterError>().having(
              (e) => e.message,
              'message',
              startsWith(
                'A ValueNotifier<double> was used after being disposed',
              ),
            ),
          ),
        );
      });
    });
  });
}
