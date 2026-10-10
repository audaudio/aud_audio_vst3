// @license
// Copyright (c) Audanika. All Rights Reserved.
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'package:aud_audio_core/aud_audio_core.dart';
import 'package:aud_audio_ui_controls/aud_audio_ui_controls.dart';
import 'package:aud_audio_vst3/aud_audio_vst3.dart';
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
  const address = AudParamAddress('filter', 'cutoff');
  const unknown = AudParamAddress('osc', 'nothing');

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

    test('sends a value as a set-param command with the input stamp', () {
      sink.setValue(address, 440);
      final message = sent.single as AudShellCommand;
      final command = message.command as AudSetParamCommand;
      expect(command.node, 2);
      expect(command.paramIndex, 0);
      expect(command.value, 440);
      expect(message.input, 42);
      expect(message.instance, 3);
    });

    test('sends the gesture phases', () {
      sink.beginGesture(address);
      sink.endGesture(address);
      final phases = sent.cast<AudShellGesture>().map((g) => g.phase);
      expect(phases, [AudShellGesturePhase.begin, AudShellGesturePhase.end]);
      expect(sent.cast<AudShellGesture>().first.node, 2);
    });

    test('ignores unknown parameters', () {
      sink.setValue(unknown, 1);
      sink.beginGesture(unknown);
      sink.receive(const AudShellParamValue(id: 99, value: 1));
      expect(sent, isEmpty);
      expect(applied, isEmpty);
    });

    test('passes values of the plugin on as changes', () async {
      final changes = <AudParamChange>[];
      final subscription = sink.changes.listen(changes.add);
      sink.receive(const AudShellParamValue(id: 7, value: 500, sequence: 4));
      expect(changes.single, const AudParamChange(address, 500));
      expect(applied.single.sequence, 4);
      await subscription.cancel();
    });

    test('finds a parameter by its address', () {
      expect(sink.param(address), cutoff);
      expect(sink.param(unknown), isNull);
    });
  });
}
