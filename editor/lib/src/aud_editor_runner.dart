// @license
// Copyright (c) Audanika. All Rights Reserved.
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'package:aud_audio_vst3/aud_audio_vst3.dart';
import 'package:flutter/services.dart';

// #############################################################################
/// The native runner of the editor (macos/Runner/MainFlutterWindow.swift):
/// a window and a Flutter view per plugin instance, placed over the
/// plugin's view.
class AudEditorRunner {
  // ...........................................................................
  /// Creates the runner's channel.
  const AudEditorRunner([
    this._channel = const MethodChannel('aud_vst3_editor/runner'),
  ]);

  final MethodChannel _channel;

  // ...........................................................................
  /// Creates the view of [instance] and returns its view id, or -1 when
  /// the engine takes no further view (no multi-view).
  Future<int> addView(int instance, AudShellWelcome welcome) async =>
      (await _channel.invokeMethod<int>('addView', {
        'instance': instance,
        'width': welcome.width,
        'height': welcome.height,
      }))!;

  // ...........................................................................
  /// Places the view of [place]'s instance over the plugin's view.
  Future<void> place(AudShellPlace place) => _channel.invokeMethod('place', {
    'instance': place.instance,
    'x': place.x,
    'y': place.y,
    'width': place.width,
    'height': place.height,
    'scale': place.scale,
    'window': place.window,
    'visible': place.visible,
  });

  // ...........................................................................
  /// Shows or hides the view of [instance]: a hidden view sends no frames.
  Future<void> visible(int instance, bool visible) => _channel.invokeMethod(
    'visible',
    {'instance': instance, 'visible': visible},
  );

  // ...........................................................................
  /// Drops the view of [instance].
  Future<void> removeView(int instance) =>
      _channel.invokeMethod('removeView', {'instance': instance});

  // ...........................................................................
  /// Quits the editor process.
  Future<void> quit() => _channel.invokeMethod('quit');
}
