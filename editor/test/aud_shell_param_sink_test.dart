// @license
// Copyright (c) Audanika. All Rights Reserved.
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'package:aud_audio_core/aud_audio_core.dart';
import 'package:aud_audio_ui_controls/aud_audio_ui_controls.dart';
import 'package:aud_audio_vst3/aud_audio_vst3.dart';
import 'package:aud_audio_vst3_editor/src/aud_mach_clock.dart';
import 'package:aud_audio_vst3_editor/src/aud_shell_param_sink.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const cutoff = AudShellParam(
    id: 7,
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
  const address = AudParamAddress(nodeId: 'filter', paramId: 'cutoff');
  const unknown = AudParamAddress(nodeId: 'osc', paramId: 'nothing');

  group('AudShellParamSink', () {
    late List<AudShellMessage> sent;
    late List<AudShellParamValue> applied;
    late AudShellParamSink sink;

    setUp(() {
      sent = [];
      applied = [];
      sink = AudShellParamSink(
        send: sent.add,
        params: const [cutoff],
        inputStamp: () => 42,
        instance: 3,
        onApplied: applied.add,
      );
    });

    tearDown(() => sink.close());

    // What the sink sent, as JSON.
    List<Map<String, Object?>> sentJson() => [
      for (final message in sent) message.toJson(),
    ];

    group('setValue(address, value)', () {
      test('sends a set-param command with the input stamp', () {
        sink.setValue(address, 440);
        expect(sentJson(), [
          const AudShellCommand(
            AudSetParamCommand(node: 2, paramIndex: 0, value: 440),
            input: 42,
            instance: 3,
          ).toJson(),
        ]);
      });
    });

    group('beginGesture(address), endGesture(address)', () {
      test('send the gesture phases', () {
        sink.beginGesture(address);
        sink.endGesture(address);
        expect(sentJson(), [
          for (final phase in AudShellGesturePhase.values)
            AudShellGesture(
              instance: 3,
              node: 2,
              paramIndex: 0,
              phase: phase,
            ).toJson(),
        ]);
      });
    });

    group('receive(value)', () {
      test('passes a value of the plugin on as a change', () async {
        final changes = <AudParamChange>[];
        final subscription = sink.changes.listen(changes.add);
        const value = AudShellParamValue(id: 7, value: 500, sequence: 4);
        sink.receive(value);
        expect(changes, [const AudParamChange(address: address, value: 500)]);
        expect(applied, [value]);
        await subscription.cancel();
      });
    });

    test('ignores unknown parameters', () {
      sink.setValue(unknown, 1);
      sink.beginGesture(unknown);
      sink.receive(const AudShellParamValue(id: 99, value: 1));
      expect(sent, isEmpty);
      expect(applied, isEmpty);
    });

    group('param(address)', () {
      test('finds a parameter by its address', () {
        expect([sink.param(address), sink.param(unknown)], [cutoff, null]);
      });
    });
  });

  group('audProbeApplied(send, instance)', () {
    late List<AudShellMessage> sent;

    setUp(() => sent = []);

    test('probes a numbered change with its sequence, id and time', () {
      final before = AudMachClock.nowNs();
      audProbeApplied(send: sent.add, instance: 3)(
        const AudShellParamValue(id: 7, value: 500, sequence: 4),
      );
      final after = AudMachClock.nowNs();
      expect(
        [for (final message in sent) message.toJson()],
        [
          {
            'type': 'probe',
            'instance': 3,
            'kind': 'paramApplied',
            'fields': {'seq': 4, 'id': 7, 't': inInclusiveRange(before, after)},
          },
        ],
      );
    });

    test('probes no change without a number', () {
      audProbeApplied(send: sent.add)(
        const AudShellParamValue(id: 7, value: 500),
      );
      expect(sent, isEmpty);
    });
  });
}
