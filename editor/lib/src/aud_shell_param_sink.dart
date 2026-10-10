// @license
// Copyright (c) Audanika. All Rights Reserved.
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:async';

import 'package:aud_audio_core/aud_audio_core.dart';
import 'package:aud_audio_ui_controls/aud_audio_ui_controls.dart';
import 'package:aud_audio_vst3/aud_audio_vst3.dart';

// #############################################################################
/// The parameter sink of the editor: edits go to the plugin as
/// [AudSetParamCommand]s over the shell protocol, gestures as
/// [AudShellGesture]s, and the plugin's [AudShellParamValue]s come back as
/// changes. Every command carries the time stamp of the input event behind
/// it, for the latency probe.
class AudShellParamSink implements AudParamSink {
  // ...........................................................................
  /// Creates the sink over [send] for [params].
  ///
  /// - [inputStamp] the time stamp of the latest input event
  /// - [onApplied] runs after a value from the plugin moved a control
  AudShellParamSink({
    required this.send,
    required List<AudShellParam> params,
    required this.inputStamp,
    this.instance = 0,
    this.onApplied,
  }) : _byAddress = {
         for (final p in params) AudParamAddress(p.nodeId, p.paramId): p,
       },
       _byId = {for (final p in params) p.id: p};

  // ...........................................................................
  /// Sends a message to the plugin.
  final void Function(AudShellMessage message) send;

  // ...........................................................................
  /// The plugin instance of the sink.
  final int instance;

  // ...........................................................................
  /// The time stamp of the latest input event.
  final int Function() inputStamp;

  // ...........................................................................
  /// Runs after a value from the plugin moved a control.
  final void Function(AudShellParamValue value)? onApplied;

  final Map<AudParamAddress, AudShellParam> _byAddress;
  final Map<int, AudShellParam> _byId;
  final _changes = StreamController<AudParamChange>.broadcast(sync: true);

  @override
  Stream<AudParamChange> get changes => _changes.stream;

  @override
  void beginGesture(AudParamAddress address) =>
      _gesture(address, AudShellGesturePhase.begin);

  @override
  void endGesture(AudParamAddress address) =>
      _gesture(address, AudShellGesturePhase.end);

  @override
  void setValue(AudParamAddress address, double value) {
    final param = _byAddress[address];
    if (param == null) return;
    send(
      AudShellCommand(
        AudSetParamCommand(
          node: param.node,
          paramIndex: param.index,
          value: value,
        ),
        input: inputStamp(),
        instance: instance,
      ),
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
    onApplied?.call(value);
  }

  // ...........................................................................
  /// The parameter of [address], if the plugin has it.
  AudShellParam? param(AudParamAddress address) => _byAddress[address];

  // ...........................................................................
  /// Closes the change stream.
  Future<void> close() => _changes.close();

  void _gesture(AudParamAddress address, AudShellGesturePhase phase) {
    final param = _byAddress[address];
    if (param == null) return;
    send(
      AudShellGesture(
        instance: instance,
        node: param.node,
        paramIndex: param.index,
        phase: phase,
      ),
    );
  }
}
