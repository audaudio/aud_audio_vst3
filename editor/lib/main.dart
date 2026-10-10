// @license
// Copyright (c) Audanika. All Rights Reserved.
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:async';
import 'dart:io';

import 'package:aud_audio_ui_controls/aud_audio_ui_controls.dart';
import 'package:aud_audio_vst3/aud_audio_vst3.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';

import 'src/aud_editor_app.dart';
import 'src/aud_editor_instance.dart';
import 'src/aud_editor_runner.dart';
import 'src/aud_in_process_sink.dart';
import 'src/aud_input_injector.dart';
import 'src/aud_mach_clock.dart';
import 'src/aud_shell_param_sink.dart';

// #############################################################################
/// The editor process of the aud_audio_vst3 spike (ticket 24). The plugin
/// starts it with `--socket <path> --token <hex> --instance <n>` (and the
/// runner's own options). One process serves one plugin instance (A, F) or
/// every instance of the plugin build in the DAW process (S): each instance
/// gets a Flutter view of the one engine. With `--inprocess` it runs inside
/// the DAW process (B). Without either it shows the knobs over an
/// in-memory sink, for development.
Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  if (args.contains('--inprocess')) {
    await runInProcess();
    return;
  }
  final socket = _option(args, '--socket');
  if (socket == null) {
    runApp(
      AudEditorApp(
        params: _demoParams,
        sink: AudMemoryParamSink(),
        meter: ValueNotifier<double>(0.3),
      ),
    );
    return;
  }

  const runner = AudEditorRunner();
  final AudShellClient client;
  try {
    client = await AudShellClient.connect(
      socket,
      AudShellHello(
        token: _option(args, '--token') ?? '',
        instance: int.tryParse(_option(args, '--instance') ?? '') ?? 0,
        pid: pid,
      ),
    );
  } on Object {
    // The plugin is gone (or never listened): nothing to show.
    await runner.quit();
    return;
  }
  final editor = _Editor(client, runner);
  client.messages.listen(
    editor.receive,
    onDone: () => unawaited(runner.quit()),
    onError: (Object _) => unawaited(runner.quit()),
  );
}

// The instances of the process and the routing of the plugin's messages.
// #############################################################################
class _Editor {
  _Editor(this.client, this.runner);

  final AudShellClient client;
  final AudEditorRunner runner;
  final instances = ValueNotifier<Map<int, AudEditorInstance>>({});
  final Map<int, List<AudShellMessage>> _waiting = {};
  bool _running = false;

  void receive(AudShellMessage message) {
    if (message is AudShellClose) {
      unawaited(runner.quit());
      return;
    }
    if (message is AudShellWelcome) {
      unawaited(_open(message));
      return;
    }
    final instance = instances.value[message.instance];
    if (instance == null) {
      // The view of the instance is still being made.
      _waiting[message.instance]?.add(message);
      return;
    }
    _route(instance, message);
  }

  void _route(AudEditorInstance instance, AudShellMessage message) {
    switch (message) {
      case AudShellInput():
        instance.injector.handle(message);
      case AudShellParamValue():
        instance.sink.receive(message);
      case AudShellMeter():
        instance.meter.value = message.peak;
      case AudShellPlace():
        unawaited(runner.place(message));
      case AudShellHide():
        // A pointer still down belongs to a view that went away: its
        // gesture ends here, as the plugin ended it in the host.
        instance.injector.cancel();
        unawaited(runner.visible(message.instance, false));
      case AudShellShow():
        unawaited(_show(instance));
      case AudShellRemove():
        unawaited(_remove(message.instance));
      default:
        break;
    }
  }

  // Makes the view of a new instance, or brings a warm one up to date.
  Future<void> _open(AudShellWelcome welcome) async {
    final existing = instances.value[welcome.instance];
    if (existing != null) {
      for (final param in welcome.params) {
        existing.sink.receive(
          AudShellParamValue(id: param.id, value: param.value),
        );
      }
      return;
    }
    if (_waiting.containsKey(welcome.instance)) return;
    _waiting[welcome.instance] = [];
    final viewId = await runner.addView(welcome.instance, welcome);
    if (viewId < 0) {
      // The engine takes no further view (no multi-view).
      _waiting.remove(welcome.instance);
      client.send(
        AudShellProbe('error', {
          'message': 'no view: multi-view is missing',
        }, instance: welcome.instance),
      );
      return;
    }
    final dispatcher = WidgetsBinding.instance.platformDispatcher;
    while (dispatcher.view(id: viewId) == null) {
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    final injector = AudInputInjector(
      dispatch: GestureBinding.instance.handlePointerEvent,
      viewId: viewId,
      instance: welcome.instance,
    );
    final sink = AudShellParamSink(
      send: client.send,
      params: welcome.params,
      instance: welcome.instance,
      inputStamp: () => injector.lastStamp,
      onApplied: (value) {
        if (value.sequence == 0) return;
        client.send(
          AudShellProbe('paramApplied', {
            'seq': value.sequence,
            'id': value.id,
            't': AudMachClock.nowNs(),
          }, instance: welcome.instance),
        );
      },
    );
    final instance = AudEditorInstance(
      instance: welcome.instance,
      viewId: viewId,
      welcome: welcome,
      sink: sink,
      injector: injector,
    );
    instances.value = {...instances.value, welcome.instance: instance};
    if (!_running) {
      _running = true;
      runWidget(_EditorViews(editor: this));
    }
    for (final message in _waiting.remove(welcome.instance)!) {
      _route(instance, message);
    }
    client.send(
      AudShellProbe('editorReady', {
        't': AudMachClock.nowNs(),
      }, instance: welcome.instance),
    );
  }

  // Shows the view and tells the plugin, which takes it as the first frame
  // of the following window (F).
  Future<void> _show(AudEditorInstance instance) async {
    await runner.visible(instance.instance, true);
    client.send(
      AudShellProbe('shown', {
        't': AudMachClock.nowNs(),
      }, instance: instance.instance),
    );
  }

  Future<void> _remove(int instance) async {
    final removed = instances.value[instance];
    if (removed == null) return;
    removed.injector.cancel();
    instances.value = {...instances.value}..remove(instance);
    await runner.removeView(instance);
    await removed.dispose();
  }
}

// Every instance's editor in its own view.
// #############################################################################
class _EditorViews extends StatelessWidget {
  const _EditorViews({required this.editor});

  final _Editor editor;

  @override
  Widget build(BuildContext context) =>
      ValueListenableBuilder<Map<int, AudEditorInstance>>(
        valueListenable: editor.instances,
        builder: (context, instances, _) {
          final dispatcher = WidgetsBinding.instance.platformDispatcher;
          return ViewCollection(
            views: [
              for (final instance in instances.values)
                View(
                  key: ValueKey(instance.instance),
                  view: dispatcher.view(id: instance.viewId)!,
                  child: AudEditorApp(
                    params: instance.welcome.params,
                    sink: instance.sink,
                    meter: instance.meter,
                    onCursor: (kind) => editor.client.send(
                      AudShellCursor(kind, instance: instance.instance),
                    ),
                  ),
                ),
            ],
          );
        },
      );
}

String? _option(List<String> args, String name) {
  final index = args.indexOf(name);
  return index >= 0 && index + 1 < args.length ? args[index + 1] : null;
}

const _demoParams = [
  AudShellParam(
    id: 1,
    nodeId: 'osc',
    paramId: 'frequency',
    node: 1,
    index: 0,
    name: 'Frequency',
    unit: 'Hz',
    min: 20,
    max: 20000,
    defaultValue: 440,
    value: 220,
    logarithmic: true,
  ),
  AudShellParam(
    id: 2,
    nodeId: 'osc',
    paramId: 'amplitude',
    node: 1,
    index: 1,
    name: 'Amplitude',
    unit: '',
    min: 0,
    max: 1,
    defaultValue: 0.5,
    value: 0.2,
  ),
  AudShellParam(
    id: 3,
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
  ),
  AudShellParam(
    id: 4,
    nodeId: 'filter',
    paramId: 'resonance',
    node: 2,
    index: 1,
    name: 'Resonance',
    unit: '',
    min: 0,
    max: 1,
    defaultValue: 0.2,
    value: 0.3,
  ),
  AudShellParam(
    id: 5,
    nodeId: 'out',
    paramId: 'master',
    node: 3,
    index: 8,
    name: 'Master',
    unit: '',
    min: 0,
    max: 4,
    defaultValue: 1,
    value: 0.5,
  ),
];
