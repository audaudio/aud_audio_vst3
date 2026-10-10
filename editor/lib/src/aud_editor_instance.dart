// @license
// Copyright (c) Audanika. All Rights Reserved.
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'package:aud_audio_vst3/aud_audio_vst3.dart';
import 'package:flutter/foundation.dart';

import 'aud_input_injector.dart';
import 'aud_shell_param_sink.dart';

// #############################################################################
/// What the editor process keeps per plugin instance: its view, its sink,
/// its input and its meter.
class AudEditorInstance {
  // ...........................................................................
  /// Creates the instance.
  AudEditorInstance({
    required this.instance,
    required this.viewId,
    required this.welcome,
    required this.sink,
    required this.injector,
  });

  // ...........................................................................
  /// The plugin instance.
  final int instance;

  // ...........................................................................
  /// The Flutter view of the instance.
  final int viewId;

  // ...........................................................................
  /// The parameters the plugin sent.
  final AudShellWelcome welcome;

  // ...........................................................................
  /// Where the knobs' edits go.
  final AudShellParamSink sink;

  // ...........................................................................
  /// The forwarded input.
  final AudInputInjector injector;

  // ...........................................................................
  /// The output peak.
  final ValueNotifier<double> meter = ValueNotifier<double>(0);

  // ...........................................................................
  /// Releases the instance.
  Future<void> dispose() async {
    meter.dispose();
    await sink.close();
  }
}
