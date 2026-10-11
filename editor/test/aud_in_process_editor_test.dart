// @license
// Copyright (c) Audanika. All Rights Reserved.
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:ui';

import 'package:aud_audio_ui_controls/aud_audio_ui_controls.dart';
import 'package:aud_audio_vst3/aud_audio_vst3.dart';
import 'package:aud_audio_vst3_editor/src/aud_editor_layout.dart';
import 'package:aud_audio_vst3_editor/src/aud_in_process_editor.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // The channel of the plugin's view (src/aud_vst3_flutter_view.mm).
  const channel = MethodChannel('aud_vst3/plugin');
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
  const cutoff = AudShellParam(
    id: 3,
    nodeId: 'filter',
    paramId: 'cutoff',
    node: 2,
    index: 0,
    name: 'Cutoff',
    unit: 'Hz',
    min: 20,
    max: 20000,
    defaultValue: 1000,
    value: 1200,
    logarithmic: true,
  );

  group('runInProcess()', () {
    late List<MethodCall> calls;
    late PointerDataPacketCallback? handlePointers;

    setUp(() {
      calls = [];
      handlePointers = PlatformDispatcher.instance.onPointerDataPacket;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call);
            return null;
          });
    });

    tearDown(() {
      PlatformDispatcher.instance.onPointerDataPacket = handlePointers;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    // A method call of the plugin's view.
    Future<void> fromPlugin(String method, Object? arguments) async {
      await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .handlePlatformMessage(
            channel.name,
            channel.codec.encodeMethodCall(MethodCall(method, arguments)),
            (_) {},
          );
    }

    // Runs the editor and welcomes it with [params].
    Future<void> start(WidgetTester tester, List<AudShellParam> params) async {
      final running = runInProcess();
      await tester.pump();
      await fromPlugin('welcome', {
        'params': [for (final param in params) param.toJson()],
      });
      await running;
      await tester.pump();
    }

    // What the plugin received after `ready`: method and arguments.
    List<List<Object?>> received() => [
      for (final call in calls.skip(1)) [call.method, call.arguments],
    ];

    // A pointer packet of the platform: the mouse at [position] with the
    // time stamp [micros] of its NSEvent.
    void pointer(
      WidgetTester tester,
      PointerChange change,
      Offset position,
      int micros,
    ) {
      final ratio = tester.view.devicePixelRatio;
      final pressed =
          change == PointerChange.down || change == PointerChange.move;
      PlatformDispatcher.instance.onPointerDataPacket!(
        PointerDataPacket(
          data: [
            PointerData(
              viewId: tester.view.viewId,
              timeStamp: Duration(microseconds: micros),
              change: change,
              kind: PointerDeviceKind.mouse,
              physicalX: position.dx * ratio,
              physicalY: position.dy * ratio,
              buttons: pressed ? kPrimaryButton : 0,
            ),
          ],
        ),
      );
    }

    testWidgets('says it is ready, then shows the welcomed knobs', (
      tester,
    ) async {
      await start(tester, [amplitude, cutoff]);
      expect(calls.first.method, 'ready');
      final knobs = tester.widgetList<AudParamKnob>(find.byType(AudParamKnob));
      expect([for (final knob in knobs) knob.label], ['Level', 'Cutoff']);
    });

    testWidgets('sends a drag as gesture and edit, stamped with the input', (
      tester,
    ) async {
      await start(tester, [amplitude]);
      const knob = Offset(
        AudEditorLayout.knobLeft + AudEditorLayout.knobSpacing + 40,
        AudEditorLayout.knobTop + 40,
      );
      const above = Offset(0, -20);
      pointer(tester, PointerChange.add, knob, 1000);
      pointer(tester, PointerChange.down, knob, 2000);
      pointer(tester, PointerChange.move, knob + above, 3000);
      pointer(tester, PointerChange.up, knob + above, 4000);
      pointer(tester, PointerChange.remove, knob + above, 5000);
      expect(received(), [
        [
          'gesture',
          {'node': 1, 'paramIndex': 1, 'phase': 'begin'},
        ],
        [
          'command',
          {
            'node': 1,
            'paramIndex': 1,
            'value': closeTo(0.3, 1e-9),
            'input': 3000 * 1000,
          },
        ],
        [
          'gesture',
          {'node': 1, 'paramIndex': 1, 'phase': 'end'},
        ],
      ]);
    });

    testWidgets('applies values of the plugin, probes the numbered ones', (
      tester,
    ) async {
      await start(tester, [amplitude]);
      await fromPlugin('param', {'id': 2, 'value': 0.8, 'seq': 5});
      await fromPlugin('param', {'id': 2, 'value': 0.6, 'seq': 0});
      final knob = tester.widget<AudParamKnob>(find.byType(AudParamKnob));
      expect(knob.binding.plainValue, closeTo(0.6, 1e-9));
      expect(received(), [
        [
          'probe',
          {
            'kind': 'paramApplied',
            'fields': {'seq': 5, 'id': 2, 't': isA<int>()},
          },
        ],
      ]);
    });

    testWidgets('paints the meter at the peak of the plugin', (tester) async {
      await start(tester, []);
      await fromPlugin('meter', {'peak': 0.5, 'rms': 0.1});
      await tester.pump();
      final box = find.descendant(
        of: find.byWidgetPredicate(
          (widget) =>
              widget is Positioned && widget.left == AudEditorLayout.meterLeft,
        ),
        matching: find.byType(CustomPaint),
      );
      final size = tester.getSize(box);
      expect(
        box,
        paints
          ..rect(rect: Offset.zero & size)
          ..rect(
            rect: Rect.fromLTWH(
              0,
              size.height / 2,
              size.width,
              size.height / 2,
            ),
          ),
      );
    });
  });
}
