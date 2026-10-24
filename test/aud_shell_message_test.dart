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
  );
  const paramJson = {
    'id': 7,
    'nodeId': 'filter',
    'paramId': 'cutoff',
    'node': 2,
    'index': 0,
    'name': 'Cutoff',
    'unit': 'Hz',
    'min': 20,
    'max': 20000,
    'default': 1000,
    'value': 1200,
    'logarithmic': true,
    'steps': 0,
  };
  const setParam = AudSetParamCommand(node: 2, paramIndex: 0, value: 440);

  // Every message with the JSON the plugin's C++ side reads and writes.
  final cases = <(AudShellMessage, Map<String, Object?>)>[
    (
      const AudShellHello(token: 'abc', instance: 1, pid: 42),
      {
        'type': 'hello',
        'instance': 1,
        'token': 'abc',
        'pid': 42,
        'version': audShellProtocolVersion,
      },
    ),
    (
      const AudShellWelcome(
        instance: 1,
        name: 'spike',
        params: [param],
        width: 620,
        height: 220,
        scale: 2,
      ),
      {
        'type': 'welcome',
        'instance': 1,
        'name': 'spike',
        'params': [paramJson],
        'width': 620,
        'height': 220,
        'scale': 2,
        'version': audShellProtocolVersion,
        'presets': <Object?>[],
        'preset': -1,
        'settings': '',
      },
    ),
    (
      const AudShellWelcome(
        instance: 2,
        name: 'Audanika',
        params: [],
        width: 1024,
        height: 640,
        scale: 2,
        presets: [AudShellPresetInfo(id: 'a', name: 'A')],
        preset: 0,
        settings: '{"hold":true}',
      ),
      {
        'type': 'welcome',
        'instance': 2,
        'name': 'Audanika',
        'params': <Object?>[],
        'width': 1024,
        'height': 640,
        'scale': 2,
        'version': audShellProtocolVersion,
        'presets': [
          {'id': 'a', 'name': 'A'},
        ],
        'preset': 0,
        'settings': '{"hold":true}',
      },
    ),
    (
      const AudShellPreset(3, instance: 1),
      {'type': 'preset', 'instance': 1, 'index': 3},
    ),
    (
      const AudShellSelectPreset(4, instance: 1),
      {'type': 'selectPreset', 'instance': 1, 'index': 4},
    ),
    (
      const AudShellSettings('{"hold":true}', instance: 1),
      {'type': 'settings', 'instance': 1, 'settings': '{"hold":true}'},
    ),
    (
      const AudShellMidi([0x90, 60, 100], instance: 1),
      {
        'type': 'midi',
        'instance': 1,
        'bytes': [0x90, 60, 100],
      },
    ),
    (
      const AudShellCommand(setParam, input: 99, instance: 4),
      {
        'type': 'command',
        'instance': 4,
        'command': setParam.toJson(),
        'input': 99,
      },
    ),
    (
      const AudShellGesture(
        node: 2,
        paramIndex: 0,
        phase: AudShellGesturePhase.begin,
      ),
      {
        'type': 'gesture',
        'instance': 0,
        'node': 2,
        'paramIndex': 0,
        'phase': 'begin',
      },
    ),
    (
      const AudShellParamValue(id: 7, value: 1500),
      {'type': 'param', 'instance': 0, 'id': 7, 'value': 1500},
    ),
    (
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
      {
        'type': 'input',
        'instance': 0,
        'kind': 'scroll',
        'x': 1,
        'y': 2,
        'buttons': 1,
        'dx': 3,
        'dy': 4,
        'keyCode': 5,
        'characters': 't',
        'modifiers': 6,
        'focused': true,
        't': 7,
      },
    ),
    (
      const AudShellPlace(
        x: 10,
        y: 20,
        width: 700,
        height: 300,
        scale: 1,
        window: 5,
        visible: false,
      ),
      {
        'type': 'place',
        'instance': 0,
        'x': 10,
        'y': 20,
        'width': 700,
        'height': 300,
        'scale': 1,
        'window': 5,
        'visible': false,
      },
    ),
    (
      const AudShellCursor('resizeUpDown'),
      {'type': 'cursor', 'instance': 0, 'kind': 'resizeUpDown'},
    ),
    (const AudShellShow(instance: 2), {'type': 'show', 'instance': 2}),
    (const AudShellHide(instance: 2), {'type': 'hide', 'instance': 2}),
    (const AudShellRemove(instance: 2), {'type': 'remove', 'instance': 2}),
    (const AudShellClose(), {'type': 'close'}),
  ];

  group('AudShellMessage', () {
    group('toJson()', () {
      for (final (message, json) in cases) {
        test('writes every field of ${message.runtimeType}', () {
          expect(message.toJson(), json);
        });
      }
    });

    group('fromJson(json)', () {
      for (final (message, json) in cases) {
        test('reads ${message.runtimeType} with its instance', () {
          final copy = AudShellMessage.fromJson(json);
          expect(copy.runtimeType, message.runtimeType);
          expect(copy.instance, message.instance);
          expect(copy.toJson(), json);
        });
      }

      test('takes instance 0 when the JSON names none', () {
        expect(AudShellMessage.fromJson({'type': 'show'}).instance, 0);
      });

      test('refuses an unknown type', () {
        expect(
          () => AudShellMessage.fromJson({'type': 'nonsense'}),
          throwsA(
            isA<FormatException>()
                .having((e) => e.message, 'message', 'Unknown shell message')
                .having((e) => e.source, 'source', {'type': 'nonsense'}),
          ),
        );
      });
    });

    group('toString()', () {
      test('names the type and the JSON', () {
        expect(
          const AudShellClose().toString(),
          'AudShellClose({type: close})',
        );
      });
    });
  });

  group('AudShellWelcome.fromJson(json)', () {
    test('takes no settings from a plugin of version 2', () {
      final welcome = AudShellWelcome.fromJson({
        'type': 'welcome',
        'name': 'Audanika',
        'params': <Object?>[],
        'width': 1024,
        'height': 640,
        'scale': 1,
        'version': 2,
      });
      expect(welcome.settings, isEmpty);
    });
  });

  group('AudShellParam.fromJson(json)', () {
    test('defaults logarithmic to false and steps to 0', () {
      final json = {...paramJson}
        ..remove('logarithmic')
        ..remove('steps');
      expect(AudShellParam.fromJson(json).toJson(), {
        ...json,
        'logarithmic': false,
        'steps': 0,
      });
    });
  });

  group('AudShellCommand.fromJson(json)', () {
    test('defaults the input stamp to 0', () {
      final copy = AudShellCommand.fromJson({
        'type': 'command',
        'command': setParam.toJson(),
      });
      expect(copy.toJson(), {
        'type': 'command',
        'instance': 0,
        'command': setParam.toJson(),
        'input': 0,
      });
    });
  });

  group('AudShellInput.fromJson(json)', () {
    test('defaults every field but the kind', () {
      final copy = AudShellInput.fromJson({'kind': 'hover'});
      expect(copy.toJson(), {
        'type': 'input',
        'instance': 0,
        'kind': 'hover',
        'x': 0,
        'y': 0,
        'buttons': 0,
        'dx': 0,
        'dy': 0,
        'keyCode': 0,
        'characters': '',
        'modifiers': 0,
        'focused': false,
        't': 0,
      });
    });
  });

  group('AudShellPlace.fromJson(json)', () {
    test('defaults the window to 0 and the view to visible', () {
      final copy = AudShellPlace.fromJson({
        'x': 0,
        'y': 0,
        'width': 1,
        'height': 1,
        'scale': 2,
      });
      expect(copy.toJson(), {
        'type': 'place',
        'instance': 0,
        'x': 0,
        'y': 0,
        'width': 1,
        'height': 1,
        'scale': 2,
        'window': 0,
        'visible': true,
      });
    });
  });
}
