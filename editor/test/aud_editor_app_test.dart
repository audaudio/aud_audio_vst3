// @license
// Copyright (c) Audanika. All Rights Reserved.
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'package:aud_audio_ui_controls/aud_audio_ui_controls.dart';
import 'package:aud_audio_vst3/aud_audio_vst3.dart';
import 'package:aud_audio_vst3_editor/src/aud_editor_app.dart';
import 'package:aud_audio_vst3_editor/src/aud_editor_layout.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const frequency = AudShellParam(
    id: 1,
    nodeId: 'osc',
    paramId: 'frequency',
    node: 1,
    index: 0,
    name: 'Frequency',
    unit: 'Hz',
    min: 20,
    max: 20000,
    defaultValue: 440,
    value: 220,
    logarithmic: true,
  );
  const amplitude = AudShellParam(
    id: 2,
    nodeId: 'osc',
    paramId: 'amplitude',
    node: 1,
    index: 1,
    name: 'Amplitude',
    unit: '',
    min: 0,
    max: 1,
    defaultValue: 0.5,
    value: 0.2,
  );
  // A parameter the layout has no knob for.
  const detune = AudShellParam(
    id: 3,
    nodeId: 'osc',
    paramId: 'detune',
    node: 1,
    index: 2,
    name: 'Detune',
    unit: 'ct',
    min: -100,
    max: 100,
    defaultValue: 0,
    value: 0,
    steps: 201,
  );

  group('audSpecOf(param)', () {
    test('takes address, range, scale, steps, name and unit', () {
      final spec = audSpecOf(detune);
      expect(
        [
          spec.address.path,
          spec.min,
          spec.max,
          spec.defaultValue,
          spec.logarithmic,
          spec.steps,
          spec.name,
          spec.unit,
        ],
        ['/osc/detune', -100, 100, 0, false, 201, 'Detune', 'ct'],
      );
    });
  });

  group('AudEditorApp', () {
    late AudMemoryParamSink sink;
    late ValueNotifier<double> meter;
    late List<String> cursors;

    setUp(() {
      sink = AudMemoryParamSink();
      meter = ValueNotifier<double>(0.25);
      cursors = [];
    });

    tearDown(() async {
      meter.dispose();
      await sink.close();
    });

    // Shows the editor of [params].
    Future<void> pumpEditor(WidgetTester tester, List<AudShellParam> params) =>
        tester.pumpWidget(
          AudEditorApp(
            params: params,
            sink: sink,
            meter: meter,
            onCursor: cursors.add,
          ),
        );

    // The knobs the editor shows.
    List<AudParamKnob> knobs(WidgetTester tester) =>
        tester.widgetList<AudParamKnob>(find.byType(AudParamKnob)).toList();

    // The center of the knob in the layout's slot [index].
    Offset knobCenter(int index) => Offset(
      AudEditorLayout.knobLeftOf(index) + AudEditorLayout.knobSize / 2,
      AudEditorLayout.knobTop + AudEditorLayout.knobSize / 2,
    );

    testWidgets('shows a knob per parameter the layout places', (tester) async {
      await pumpEditor(tester, [detune, amplitude, frequency]);
      expect(
        [for (final knob in knobs(tester)) knob.label],
        ['Frequency', 'Level'],
      );
      expect(
        [for (final knob in knobs(tester)) knob.binding.plainValue],
        [closeTo(220, 1e-9), closeTo(0.2, 1e-9)],
      );
    });

    testWidgets('sends a drag of a knob to the sink', (tester) async {
      await pumpEditor(tester, [frequency, amplitude]);
      final gesture = await tester.startGesture(knobCenter(1));
      await gesture.moveBy(const Offset(0, -20));
      await gesture.up();
      expect(sink.calls, [
        'begin /osc/amplitude',
        startsWith('set /osc/amplitude 0.3'),
        'end /osc/amplitude',
      ]);
    });

    testWidgets('asks for the resize cursor over a knob', (tester) async {
      await pumpEditor(tester, [frequency]);
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: Offset.zero);
      await mouse.moveTo(knobCenter(0));
      await mouse.moveTo(Offset.zero);
      await mouse.removePointer();
      expect(cursors, ['resizeUpDown', 'basic']);
    });

    testWidgets('paints the meter at the peak, at most full', (tester) async {
      await pumpEditor(tester, []);
      final box = find.descendant(
        of: find.byWidgetPredicate(
          (widget) =>
              widget is Positioned && widget.left == AudEditorLayout.meterLeft,
        ),
        matching: find.byType(CustomPaint),
      );
      final size = tester.getSize(box);
      // The background, then the level from the bottom.
      Rect level(double peak) => Rect.fromLTWH(
        0,
        size.height * (1 - peak),
        size.width,
        size.height * peak,
      );
      expect(
        box,
        paints
          ..rect(rect: Offset.zero & size)
          ..rect(rect: level(0.25)),
      );
      meter.value = 2;
      await tester.pump();
      expect(
        box,
        paints
          ..rect(rect: Offset.zero & size)
          ..rect(rect: level(1)),
      );
    });

    testWidgets('releases its bindings when it goes away', (tester) async {
      await pumpEditor(tester, [frequency]);
      final binding = knobs(tester).single.binding;
      await tester.pumpWidget(const SizedBox());
      expect(
        () => binding.addListener(() {}),
        throwsA(
          isA<FlutterError>().having(
            (e) => e.message,
            'message',
            startsWith('A AudParamBinding was used after being disposed'),
          ),
        ),
      );
    });
  });
}
