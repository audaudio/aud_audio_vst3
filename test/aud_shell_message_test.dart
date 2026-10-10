// @license
// Copyright (c) Audanika. All Rights Reserved.
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'package:aud_audio_core/aud_audio_core.dart';
import 'package:aud_audio_vst3/aud_audio_vst3.dart';
import 'package:test/test.dart';

void main() {
  const param = AudShellParam(
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
    steps: 0,
  );

  // Every message through JSON and back.
  final messages = <AudShellMessage>[
    const AudShellHello(token: 'abc', instance: 1, pid: 42),
    const AudShellWelcome(
      instance: 1,
      name: 'spike',
      params: [param],
      width: 620,
      height: 220,
      scale: 2,
    ),
    const AudShellCommand(
      AudSetParamCommand(node: 2, paramIndex: 0, value: 440),
      input: 99,
      instance: 4,
    ),
    const AudShellGesture(
      node: 2,
      paramIndex: 0,
      phase: AudShellGesturePhase.begin,
    ),
    const AudShellParamValue(id: 7, value: 1500, sequence: 3),
    const AudShellMeter(peak: 0.5, rms: 0.25),
    const AudShellInput(
      kind: AudShellInputKind.scroll,
      x: 1,
      y: 2,
      buttons: 1,
      dx: 3,
      dy: 4,
      keyCode: 5,
      characters: 't',
      modifiers: 6,
      focused: true,
      time: 7,
    ),
    const AudShellPlace(
      x: 10,
      y: 20,
      width: 700,
      height: 300,
      scale: 1,
      window: 5,
      visible: false,
    ),
    const AudShellCursor('resizeUpDown'),
    const AudShellProbe('paramApplied', {'seq': 3, 't': 10}),
    const AudShellShow(instance: 2),
    const AudShellHide(instance: 2),
    const AudShellRemove(instance: 2),
    const AudShellClose(),
  ];

  group('AudShellMessage', () {
    test('reads what it writes', () {
      for (final message in messages) {
        final copy = AudShellMessage.fromJson(message.toJson());
        expect(copy.runtimeType, message.runtimeType);
        expect(copy.toJson(), message.toJson());
      }
    });

    test('keeps the instance', () {
      for (final message in messages) {
        expect(
          AudShellMessage.fromJson(message.toJson()).instance,
          message.instance,
        );
      }
      expect(AudShellMessage.fromJson({'type': 'show'}).instance, 0);
    });

    test('refuses an unknown type', () {
      expect(
        () => AudShellMessage.fromJson({'type': 'nonsense'}),
        throwsA(isA<FormatException>()),
      );
    });

    test('describes itself', () {
      expect(const AudShellClose().toString(), 'AudShellClose({type: close})');
    });
  });

  group('AudShellParam', () {
    test('takes defaults for optional fields', () {
      final json = param.toJson()
        ..remove('logarithmic')
        ..remove('steps');
      final copy = AudShellParam.fromJson(json);
      expect(copy.logarithmic, isFalse);
      expect(copy.steps, 0);
      expect(copy.nodeId, 'filter');
      expect(copy.paramId, 'cutoff');
      expect(copy.node, 2);
      expect(copy.index, 0);
      expect(copy.name, 'Cutoff');
      expect(copy.unit, 'Hz');
      expect(copy.min, 20);
      expect(copy.max, 20000);
      expect(copy.defaultValue, 1000);
      expect(copy.value, 1200);
      expect(copy.id, 7);
    });
  });

  group('AudShellCommand', () {
    test('defaults the input stamp to 0', () {
      final json = messages[2].toJson()..remove('input');
      expect((AudShellMessage.fromJson(json) as AudShellCommand).input, 0);
    });
  });

  group('AudShellParamValue', () {
    test('defaults the sequence to 0', () {
      final copy =
          AudShellMessage.fromJson({'type': 'param', 'id': 1, 'value': 2})
              as AudShellParamValue;
      expect(copy.sequence, 0);
      expect(copy.id, 1);
      expect(copy.value, 2);
    });
  });

  group('AudShellInput', () {
    test('defaults missing fields', () {
      final copy =
          AudShellMessage.fromJson({'type': 'input', 'kind': 'hover'})
              as AudShellInput;
      expect(copy.kind, AudShellInputKind.hover);
      expect(copy.x, 0);
      expect(copy.y, 0);
      expect(copy.buttons, 0);
      expect(copy.dx, 0);
      expect(copy.dy, 0);
      expect(copy.keyCode, 0);
      expect(copy.characters, '');
      expect(copy.modifiers, 0);
      expect(copy.focused, isFalse);
      expect(copy.time, 0);
    });
  });

  group('fields', () {
    test('are kept', () {
      const hello = AudShellHello(token: 't', instance: 2, pid: 3);
      expect(hello.version, audShellProtocolVersion);
      expect(hello.token, 't');
      expect(hello.instance, 2);
      expect(hello.pid, 3);
      final welcome = messages[1] as AudShellWelcome;
      expect(welcome.instance, 1);
      expect(welcome.name, 'spike');
      expect(welcome.params.single.id, 7);
      expect(welcome.width, 620);
      expect(welcome.height, 220);
      expect(welcome.scale, 2);
      expect(welcome.version, audShellProtocolVersion);
      final gesture = messages[3] as AudShellGesture;
      expect(gesture.node, 2);
      expect(gesture.paramIndex, 0);
      expect(gesture.phase, AudShellGesturePhase.begin);
      final meter = messages[5] as AudShellMeter;
      expect(meter.peak, 0.5);
      expect(meter.rms, 0.25);
      final place = messages[7] as AudShellPlace;
      expect(place.x, 10);
      expect(place.y, 20);
      expect(place.width, 700);
      expect(place.height, 300);
      expect(place.scale, 1);
      expect(place.window, 5);
      expect(place.visible, isFalse);
      final defaults = AudShellPlace.fromJson({
        'x': 0,
        'y': 0,
        'width': 1,
        'height': 1,
        'scale': 2,
      });
      expect(defaults.window, 0);
      expect(defaults.visible, isTrue);
      expect((messages[8] as AudShellCursor).kind, 'resizeUpDown');
      final probe = messages[9] as AudShellProbe;
      expect(probe.kind, 'paramApplied');
      expect(probe.fields, {'seq': 3, 't': 10});
      final command = messages[2] as AudShellCommand;
      expect(command.command, isA<AudSetParamCommand>());
      expect(command.input, 99);
    });
  });
}
