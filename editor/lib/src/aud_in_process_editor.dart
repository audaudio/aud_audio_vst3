// @license
// Copyright (c) Audanika. All Rights Reserved.
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:async';
import 'dart:ui';

import 'package:aud_audio_core/aud_audio_core.dart';
import 'package:aud_audio_vst3/aud_audio_vst3.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'aud_editor_app.dart';
import 'aud_shell_param_sink.dart';

// #############################################################################
/// Variant B of the spike (ticket 24): the editor runs in the DAW process,
/// one engine per plugin instance, its own view inside the plugin's. The
/// plugin talks over the method channel `aud_vst3/plugin` instead of the
/// socket - the same messages, as maps (src/aud_vst3_flutter_view.mm). The
/// knobs edit through an [AudShellParamSink], as in the editor process.
Future<void> runInProcess() async {
  const channel = MethodChannel('aud_vst3/plugin');
  var lastInput = 0;
  // Flutter's pointer data carry the time stamp of the NSEvent, which is
  // mach time: the stamp of the input behind an edit. It is taken before
  // the framework dispatches the event: a global pointer route would run
  // after the knob has already sent its edit, with the previous stamp.
  final dispatcher = PlatformDispatcher.instance;
  final handlePointers = dispatcher.onPointerDataPacket;
  dispatcher.onPointerDataPacket = (packet) {
    if (packet.data.isNotEmpty) {
      lastInput = packet.data.last.timeStamp.inMicroseconds * 1000;
    }
    handlePointers?.call(packet);
  };
  final meter = ValueNotifier<double>(0);
  final welcome = Completer<List<AudShellParam>>();
  AudShellParamSink? sink;
  channel.setMethodCallHandler((call) async {
    final args = call.arguments;
    switch (call.method) {
      case 'welcome':
        final params = [
          for (final param in (args as Map)['params'] as List)
            AudShellParam.fromJson(Map<String, Object?>.from(param as Map)),
        ];
        if (!welcome.isCompleted) welcome.complete(params);
      case 'param':
        sink?.receive(
          AudShellParamValue.fromJson(Map<String, Object?>.from(args as Map)),
        );
      case 'meter':
        meter.value = ((args as Map)['peak'] as num).toDouble();
    }
    return null;
  });
  await channel.invokeMethod<void>('ready');
  final params = await welcome.future;
  void send(AudShellMessage message) => _sendOver(channel, message);
  sink = AudShellParamSink(
    send: send,
    params: params,
    inputStamp: () => lastInput,
    onApplied: audProbeApplied(send: send),
  );
  runApp(AudEditorApp(params: params, sink: sink, meter: meter));
}

// Sends [message] as the method call the plugin's view handles: an edit, a
// gesture or a probe record.
void _sendOver(MethodChannel channel, AudShellMessage message) {
  final (String, Map<String, Object?>)? call = switch (message) {
    AudShellCommand(
      command: AudSetParamCommand(:final node, :final paramIndex, :final value),
      :final input,
    ) =>
      (
        'command',
        {
          'node': node,
          'paramIndex': paramIndex,
          'value': value,
          'input': input,
        },
      ),
    AudShellGesture(:final node, :final paramIndex, :final phase) => (
      'gesture',
      {'node': node, 'paramIndex': paramIndex, 'phase': phase.name},
    ),
    AudShellProbe(:final kind, :final fields) => (
      'probe',
      {'kind': kind, 'fields': fields},
    ),
    _ => null, // coverage:ignore-line
  };
  if (call == null) return;
  unawaited(channel.invokeMethod<void>(call.$1, call.$2));
}
