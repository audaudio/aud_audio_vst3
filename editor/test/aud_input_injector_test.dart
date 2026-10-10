// @license
// Copyright (c) Audanika. All Rights Reserved.
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'package:aud_audio_vst3/aud_audio_vst3.dart';
import 'package:aud_audio_vst3_editor/src/aud_input_injector.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('AudInputInjector', () {
    late List<PointerEvent> events;
    late AudInputInjector injector;

    setUp(() {
      events = [];
      injector = AudInputInjector(dispatch: events.add, viewId: 3, instance: 2);
    });

    AudShellInput input(
      AudShellInputKind kind, {
      double x = 10,
      double y = 20,
      int time = 5000000,
    }) => AudShellInput(kind: kind, x: x, y: y, time: time);

    test('adds the mouse before the first hover', () {
      injector.handle(input(AudShellInputKind.enter));
      injector.handle(input(AudShellInputKind.hover, x: 12));
      expect(events.map((e) => e.runtimeType), [
        PointerAddedEvent,
        PointerHoverEvent,
        PointerHoverEvent,
      ]);
      expect(events.last.viewId, 3);
      expect(events.last.device, 1002);
      expect(events.last.delta, const Offset(2, 0));
      expect(events.last.timeStamp, const Duration(microseconds: 5000));
      expect(injector.lastStamp, 5000000);
    });

    test('plays a drag as down, move and up', () {
      injector.handle(input(AudShellInputKind.down));
      injector.handle(input(AudShellInputKind.move, y: 10));
      injector.handle(input(AudShellInputKind.up, y: 10));
      expect(events.map((e) => e.runtimeType), [
        PointerAddedEvent,
        PointerDownEvent,
        PointerMoveEvent,
        PointerUpEvent,
      ]);
      expect(events[1].buttons, kPrimaryButton);
      expect(events[2].pointer, events[1].pointer);
      expect(events[2].delta, const Offset(0, -10));
    });

    test('turns a move without a button into a hover', () {
      injector.handle(input(AudShellInputKind.move));
      expect(events.last, isA<PointerHoverEvent>());
    });

    test('ignores an up without a down', () {
      injector.handle(input(AudShellInputKind.up));
      expect(events, isEmpty);
    });

    test('scrolls', () {
      injector.handle(
        const AudShellInput(kind: AudShellInputKind.scroll, dx: 1, dy: -40),
      );
      final scroll = events.last as PointerScrollEvent;
      expect(scroll.scrollDelta, const Offset(1, -40));
    });

    test('removes the mouse on exit, unless a button is down', () {
      injector.handle(input(AudShellInputKind.down));
      injector.handle(input(AudShellInputKind.exit));
      expect(events.last, isA<PointerDownEvent>());
      injector.handle(input(AudShellInputKind.up));
      injector.handle(input(AudShellInputKind.exit));
      expect(events.last, isA<PointerRemovedEvent>());
    });

    test('cancels a pointer that is still down', () {
      injector.cancel();
      expect(events, isEmpty);
      injector.handle(input(AudShellInputKind.down));
      injector.cancel();
      expect(events.last, isA<PointerCancelEvent>());
      expect(events.last.pointer, events[1].pointer);
      injector.handle(input(AudShellInputKind.up));
      expect(events.last, isA<PointerCancelEvent>());
    });

    test('forwards no keys', () {
      for (final kind in [
        AudShellInputKind.keyDown,
        AudShellInputKind.keyUp,
        AudShellInputKind.focus,
      ]) {
        injector.handle(input(kind));
      }
      expect(events, isEmpty);
    });
  });
}
