// @license
// Copyright (c) Audanika. All Rights Reserved.
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'package:aud_audio_vst3/aud_audio_vst3.dart';
import 'package:flutter/gestures.dart';

// #############################################################################
/// Turns the input the plugin's view forwards into Flutter pointer events
/// of the view [viewId], as if its own window had received them. The
/// injection lives in Dart, so it is the same on every desktop platform
/// (S18).
class AudInputInjector {
  // ...........................................................................
  /// Creates the injector; [dispatch] hands an event to the framework.
  AudInputInjector({required this.dispatch, this.viewId = 0, int instance = 0})
    : device = 1000 + instance;

  // ...........................................................................
  /// Hands an event to the framework, e.g.
  /// `GestureBinding.instance.handlePointerEvent`.
  final void Function(PointerEvent event) dispatch;

  // ...........................................................................
  /// The view the events belong to.
  final int viewId;

  // ...........................................................................
  /// The device id of the forwarded mouse, one per plugin instance.
  final int device;

  // ...........................................................................
  /// The time stamp of the latest input event, mach time in nanoseconds.
  int lastStamp = 0;

  bool _added = false;
  bool _down = false;
  int _pointer = 0;
  Offset _last = Offset.zero;

  // ...........................................................................
  /// Injects [input].
  void handle(AudShellInput input) {
    lastStamp = input.time;
    final position = Offset(input.x, input.y);
    final timeStamp = Duration(microseconds: input.time ~/ 1000);
    switch (input.kind) {
      case AudShellInputKind.enter:
      case AudShellInputKind.hover:
        _ensureAdded(timeStamp, position);
        dispatch(
          PointerHoverEvent(
            timeStamp: timeStamp,
            viewId: viewId,
            kind: PointerDeviceKind.mouse,
            device: device,
            position: position,
            delta: position - _last,
          ),
        );
      case AudShellInputKind.exit:
        if (_added && !_down) {
          dispatch(
            PointerRemovedEvent(
              timeStamp: timeStamp,
              viewId: viewId,
              kind: PointerDeviceKind.mouse,
              device: device,
              position: position,
            ),
          );
          _added = false;
        }
      case AudShellInputKind.down:
        _ensureAdded(timeStamp, position);
        _pointer += 1;
        _down = true;
        dispatch(
          PointerDownEvent(
            timeStamp: timeStamp,
            pointer: _pointer,
            viewId: viewId,
            kind: PointerDeviceKind.mouse,
            device: device,
            position: position,
            buttons: input.buttons == 0 ? kPrimaryButton : input.buttons,
          ),
        );
      case AudShellInputKind.move:
        if (!_down) {
          handle(
            AudShellInput(
              kind: AudShellInputKind.hover,
              x: input.x,
              y: input.y,
              time: input.time,
            ),
          );
          return;
        }
        dispatch(
          PointerMoveEvent(
            timeStamp: timeStamp,
            pointer: _pointer,
            viewId: viewId,
            kind: PointerDeviceKind.mouse,
            device: device,
            position: position,
            delta: position - _last,
            buttons: input.buttons == 0 ? kPrimaryButton : input.buttons,
          ),
        );
      case AudShellInputKind.up:
        if (_down) {
          _down = false;
          dispatch(
            PointerUpEvent(
              timeStamp: timeStamp,
              pointer: _pointer,
              viewId: viewId,
              kind: PointerDeviceKind.mouse,
              device: device,
              position: position,
            ),
          );
        }
      case AudShellInputKind.scroll:
        _ensureAdded(timeStamp, position);
        dispatch(
          PointerScrollEvent(
            timeStamp: timeStamp,
            viewId: viewId,
            kind: PointerDeviceKind.mouse,
            device: device,
            position: position,
            scrollDelta: Offset(input.dx, input.dy),
          ),
        );
      case AudShellInputKind.keyDown:
      case AudShellInputKind.keyUp:
      case AudShellInputKind.focus:
        // The spike forwards no keys into Flutter: text input and shortcuts
        // need the text input plugin of the embedding (open question 3).
        break;
    }
    _last = position;
  }

  // ...........................................................................
  /// Ends a pointer that is still down: the plugin's view went away in the
  /// middle of a drag, and the control under it must end its gesture.
  void cancel() {
    if (!_down) return;
    _down = false;
    dispatch(
      PointerCancelEvent(
        timeStamp: Duration(microseconds: lastStamp ~/ 1000),
        pointer: _pointer,
        viewId: viewId,
        kind: PointerDeviceKind.mouse,
        device: device,
        position: _last,
      ),
    );
  }

  void _ensureAdded(Duration timeStamp, Offset position) {
    if (_added) return;
    _added = true;
    dispatch(
      PointerAddedEvent(
        timeStamp: timeStamp,
        viewId: viewId,
        kind: PointerDeviceKind.mouse,
        device: device,
        position: position,
      ),
    );
  }
}
