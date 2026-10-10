// @license
// Copyright (c) Audanika. All Rights Reserved.
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:async';
import 'dart:ui';

import 'package:aud_audio_ui_controls/aud_audio_ui_controls.dart';
import 'package:aud_audio_vst3/aud_audio_vst3.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'aud_editor_app.dart';
import 'aud_mach_clock.dart';

// #############################################################################
/// Variant B of the spike (ticket 24): the editor runs in the DAW process,
/// one engine per plugin instance, its own view inside the plugin's. The
/// plugin talks over the method channel `aud_vst3/plugin` instead of the
/// socket - the same messages, as maps.
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
  AudInProcessSink? sink;
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
        final value = AudShellParamValue.fromJson(
          Map<String, Object?>.from(args as Map),
        );
        sink?.receive(value);
        if (value.sequence != 0) {
          unawaited(
            channel.invokeMethod('probe', {
              'kind': 'paramApplied',
              'fields': {
                'seq': value.sequence,
                'id': value.id,
                't': AudMachClock.nowNs(),
              },
            }),
          );
        }
      case 'meter':
        meter.value = ((args as Map)['peak'] as num).toDouble();
    }
    return null;
  });
  await channel.invokeMethod('ready');
  final params = await welcome.future;
  sink = AudInProcessSink(
    channel: channel,
    params: params,
    inputStamp: () => lastInput,
  );
  runApp(AudEditorApp(params: params, sink: sink, meter: meter));
}

// #############################################################################
/// The sink of the in-process editor: edits and gestures as method calls.
class AudInProcessSink implements AudParamSink {
  // ...........................................................................
  /// Creates the sink.
  AudInProcessSink({
    required this.channel,
    required List<AudShellParam> params,
    required this.inputStamp,
  }) : _byAddress = {
         for (final p in params) AudParamAddress(p.nodeId, p.paramId): p,
       },
       _byId = {for (final p in params) p.id: p};

  // ...........................................................................
  /// The channel to the plugin.
  final MethodChannel channel;

  // ...........................................................................
  /// The time stamp of the latest input event.
  final int Function() inputStamp;

  final Map<AudParamAddress, AudShellParam> _byAddress;
  final Map<int, AudShellParam> _byId;
  final _changes = StreamController<AudParamChange>.broadcast(sync: true);

  @override
  Stream<AudParamChange> get changes => _changes.stream;

  @override
  void beginGesture(AudParamAddress address) => _gesture(address, 'begin');

  @override
  void endGesture(AudParamAddress address) => _gesture(address, 'end');

  @override
  void setValue(AudParamAddress address, double value) {
    final param = _byAddress[address];
    if (param == null) return;
    unawaited(
      channel.invokeMethod('command', {
        'node': param.node,
        'paramIndex': param.index,
        'value': value,
        'input': inputStamp(),
      }),
    );
  }

  // ...........................................................................
  /// Applies a value the plugin sent.
  void receive(AudShellParamValue value) {
    final param = _byId[value.id];
    if (param == null) return;
    _changes.add(
      AudParamChange(AudParamAddress(param.nodeId, param.paramId), value.value),
    );
  }

  void _gesture(AudParamAddress address, String phase) {
    final param = _byAddress[address];
    if (param == null) return;
    unawaited(
      channel.invokeMethod('gesture', {
        'node': param.node,
        'paramIndex': param.index,
        'phase': phase,
      }),
    );
  }
}
