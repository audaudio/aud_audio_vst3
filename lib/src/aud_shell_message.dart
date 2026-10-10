// @license
// Copyright (c) Audanika. All Rights Reserved.
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'package:aud_audio_core/aud_audio_core.dart';

/// The version of the shell protocol that [AudShellHello] and
/// [AudShellWelcome] carry.
const int audShellProtocolVersion = 1;

// #############################################################################
/// A message of the shell protocol between a plugin shell and its editor
/// process (ticket 24, decisions 2 and 3 of the plan review): JSON objects
/// with a `type`, framed by [AudShellCodec]. Parameter edits travel as
/// [AudCommand]s; gestures, the parameter list, meters, input and the
/// editor's lifecycle are messages of the shell.
sealed class AudShellMessage {
  /// Creates a message for the plugin instance [instance].
  const AudShellMessage({this.instance = 0});

  /// A message from [toJson].
  factory AudShellMessage.fromJson(Map<String, Object?> json) =>
      switch (json['type']) {
        'hello' => AudShellHello.fromJson(json),
        'welcome' => AudShellWelcome.fromJson(json),
        'command' => AudShellCommand.fromJson(json),
        'gesture' => AudShellGesture.fromJson(json),
        'param' => AudShellParamValue.fromJson(json),
        'meter' => AudShellMeter.fromJson(json),
        'input' => AudShellInput.fromJson(json),
        'place' => AudShellPlace.fromJson(json),
        'cursor' => AudShellCursor.fromJson(json),
        'probe' => AudShellProbe.fromJson(json),
        'show' => AudShellShow(instance: _instance(json)),
        'hide' => AudShellHide(instance: _instance(json)),
        'remove' => AudShellRemove(instance: _instance(json)),
        'close' => const AudShellClose(),
        _ => throw FormatException('Unknown shell message', json),
      };

  /// The plugin instance the message belongs to: one editor process may
  /// serve every instance of a plugin in the DAW process (decision 5).
  final int instance;

  /// The message as JSON.
  Map<String, Object?> toJson();

  @override
  String toString() => '$runtimeType(${toJson()})';
}

int _instance(Map<String, Object?> json) =>
    (json['instance'] as num?)?.toInt() ?? 0;

int _int(Map<String, Object?> json, String key) => (json[key]! as num).toInt();

double _double(Map<String, Object?> json, String key) =>
    (json[key]! as num).toDouble();

// #############################################################################
/// The editor introduces itself with the token it was started with.
final class AudShellHello extends AudShellMessage {
  /// Creates the message.
  const AudShellHello({
    required this.token,
    required super.instance,
    required this.pid,
    this.version = audShellProtocolVersion,
  });

  /// A message from [toJson].
  factory AudShellHello.fromJson(Map<String, Object?> json) => AudShellHello(
    token: json['token']! as String,
    instance: _instance(json),
    pid: _int(json, 'pid'),
    version: _int(json, 'version'),
  );

  /// The token the plugin passed to the editor.
  final String token;

  /// The editor's process id.
  final int pid;

  /// The protocol version of the editor.
  final int version;

  @override
  Map<String, Object?> toJson() => {
    'type': 'hello',
    'instance': instance,
    'token': token,
    'pid': pid,
    'version': version,
  };
}

// #############################################################################
/// A parameter of the plugin's graph document, as the editor shows it.
final class AudShellParam {
  /// Creates the description.
  const AudShellParam({
    required this.id,
    required this.nodeId,
    required this.paramId,
    required this.node,
    required this.index,
    required this.name,
    required this.unit,
    required this.min,
    required this.max,
    required this.defaultValue,
    required this.value,
    this.logarithmic = false,
    this.steps = 0,
  });

  /// A description from [toJson].
  factory AudShellParam.fromJson(Map<String, Object?> json) => AudShellParam(
    id: _int(json, 'id'),
    nodeId: json['nodeId']! as String,
    paramId: json['paramId']! as String,
    node: _int(json, 'node'),
    index: _int(json, 'index'),
    name: json['name']! as String,
    unit: json['unit']! as String,
    min: _double(json, 'min'),
    max: _double(json, 'max'),
    defaultValue: _double(json, 'default'),
    value: _double(json, 'value'),
    logarithmic: json['logarithmic'] as bool? ?? false,
    steps: (json['steps'] as num?)?.toInt() ?? 0,
  );

  /// The stable id: FNV-1a of `<node id>/<param id>`, top bit cleared.
  final int id;

  /// The node id in the document.
  final String nodeId;

  /// The parameter id of the node.
  final String paramId;

  /// The node handle an [AudSetParamCommand] names.
  final int node;

  /// The parameter index an [AudSetParamCommand] names.
  final int index;

  /// The display name.
  final String name;

  /// The unit.
  final String unit;

  /// The smallest plain value.
  final double min;

  /// The largest plain value.
  final double max;

  /// The plain default.
  final double defaultValue;

  /// The current plain value.
  final double value;

  /// Whether positions map logarithmically.
  final bool logarithmic;

  /// The number of values of a stepped parameter, or 0.
  final int steps;

  /// The description as JSON.
  Map<String, Object?> toJson() => {
    'id': id,
    'nodeId': nodeId,
    'paramId': paramId,
    'node': node,
    'index': index,
    'name': name,
    'unit': unit,
    'min': min,
    'max': max,
    'default': defaultValue,
    'value': value,
    'logarithmic': logarithmic,
    'steps': steps,
  };
}

// #############################################################################
/// The plugin answers [AudShellHello]: the parameters and the editor's size.
final class AudShellWelcome extends AudShellMessage {
  /// Creates the message.
  const AudShellWelcome({
    required super.instance,
    required this.name,
    required this.params,
    required this.width,
    required this.height,
    required this.scale,
    this.version = audShellProtocolVersion,
  });

  /// A message from [toJson].
  factory AudShellWelcome.fromJson(Map<String, Object?> json) =>
      AudShellWelcome(
        instance: _instance(json),
        name: json['name']! as String,
        params: [
          for (final param in json['params']! as List<Object?>)
            AudShellParam.fromJson(param! as Map<String, Object?>),
        ],
        width: _double(json, 'width'),
        height: _double(json, 'height'),
        scale: _double(json, 'scale'),
        version: _int(json, 'version'),
      );

  /// The name of the graph document.
  final String name;

  /// The parameters of the document.
  final List<AudShellParam> params;

  /// The editor's width in points.
  final double width;

  /// The editor's height in points.
  final double height;

  /// The backing scale of the screen the editor shows on.
  final double scale;

  /// The protocol version of the plugin.
  final int version;

  @override
  Map<String, Object?> toJson() => {
    'type': 'welcome',
    'instance': instance,
    'name': name,
    'params': [for (final param in params) param.toJson()],
    'width': width,
    'height': height,
    'scale': scale,
    'version': version,
  };
}

// #############################################################################
/// An engine command of the editor, with the time stamp of the input event
/// that caused it (mach time in nanoseconds, 0 for none).
final class AudShellCommand extends AudShellMessage {
  /// Creates the message.
  const AudShellCommand(this.command, {this.input = 0, super.instance});

  /// A message from [toJson].
  factory AudShellCommand.fromJson(Map<String, Object?> json) =>
      AudShellCommand(
        AudCommand.fromJson(json['command']! as Map<String, Object?>),
        input: (json['input'] as num?)?.toInt() ?? 0,
        instance: _instance(json),
      );

  /// The command.
  final AudCommand command;

  /// The time stamp of the input event behind the command.
  final int input;

  @override
  Map<String, Object?> toJson() => {
    'type': 'command',
    'instance': instance,
    'command': command.toJson(),
    'input': input,
  };
}

// #############################################################################
/// The phase of a parameter gesture.
enum AudShellGesturePhase {
  /// The gesture starts: VST3's beginEdit.
  begin,

  /// The gesture ends: VST3's endEdit.
  end,
}

// #############################################################################
/// A parameter gesture of the editor; the plugin turns it into the host's
/// begin and end of an automation edit.
final class AudShellGesture extends AudShellMessage {
  /// Creates the message.
  const AudShellGesture({
    super.instance,
    required this.node,
    required this.paramIndex,
    required this.phase,
  });

  /// A message from [toJson].
  factory AudShellGesture.fromJson(Map<String, Object?> json) =>
      AudShellGesture(
        node: _int(json, 'node'),
        paramIndex: _int(json, 'paramIndex'),
        phase: AudShellGesturePhase.values.byName(json['phase']! as String),
        instance: _instance(json),
      );

  /// The node handle.
  final int node;

  /// The parameter index.
  final int paramIndex;

  /// Begin or end.
  final AudShellGesturePhase phase;

  @override
  Map<String, Object?> toJson() => {
    'type': 'gesture',
    'instance': instance,
    'node': node,
    'paramIndex': paramIndex,
    'phase': phase.name,
  };
}

// #############################################################################
/// A parameter changed in the plugin: through the host's automation, the
/// generic view or a state load. [sequence] counts these messages, so the
/// probes can follow one change to the screen.
final class AudShellParamValue extends AudShellMessage {
  /// Creates the message.
  const AudShellParamValue({
    super.instance,
    required this.id,
    required this.value,
    this.sequence = 0,
  });

  /// A message from [toJson].
  factory AudShellParamValue.fromJson(Map<String, Object?> json) =>
      AudShellParamValue(
        id: _int(json, 'id'),
        value: _double(json, 'value'),
        sequence: (json['seq'] as num?)?.toInt() ?? 0,
        instance: _instance(json),
      );

  /// The stable id.
  final int id;

  /// The plain value.
  final double value;

  /// The running number of the change.
  final int sequence;

  @override
  Map<String, Object?> toJson() => {
    'type': 'param',
    'instance': instance,
    'id': id,
    'value': value,
    'seq': sequence,
  };
}

// #############################################################################
/// The output meter of the plugin's graph.
final class AudShellMeter extends AudShellMessage {
  /// Creates the message.
  const AudShellMeter({super.instance, required this.peak, required this.rms});

  /// A message from [toJson].
  factory AudShellMeter.fromJson(Map<String, Object?> json) => AudShellMeter(
    instance: _instance(json),
    peak: _double(json, 'peak'),
    rms: _double(json, 'rms'),
  );

  /// The peak of the last block.
  final double peak;

  /// The root mean square of the last block.
  final double rms;

  @override
  Map<String, Object?> toJson() => {
    'type': 'meter',
    'instance': instance,
    'peak': peak,
    'rms': rms,
  };
}

// #############################################################################
/// What an input event of the plugin's view does.
enum AudShellInputKind {
  /// A button went down.
  down,

  /// The pointer moved with a button down.
  move,

  /// A button went up.
  up,

  /// The pointer moved without a button.
  hover,

  /// The pointer entered the view.
  enter,

  /// The pointer left the view.
  exit,

  /// The wheel or the trackpad scrolled.
  scroll,

  /// A key went down.
  keyDown,

  /// A key went up.
  keyUp,

  /// The view gained or lost the keyboard focus.
  focus,
}

// #############################################################################
/// An input event of the plugin's view, forwarded to the editor: positions
/// in points from the top left, the time stamp of the event in mach time
/// nanoseconds.
final class AudShellInput extends AudShellMessage {
  /// Creates the message.
  const AudShellInput({
    super.instance,
    required this.kind,
    this.x = 0,
    this.y = 0,
    this.buttons = 0,
    this.dx = 0,
    this.dy = 0,
    this.keyCode = 0,
    this.characters = '',
    this.modifiers = 0,
    this.focused = false,
    this.time = 0,
  });

  /// A message from [toJson].
  factory AudShellInput.fromJson(Map<String, Object?> json) => AudShellInput(
    kind: AudShellInputKind.values.byName(json['kind']! as String),
    x: (json['x'] as num?)?.toDouble() ?? 0,
    y: (json['y'] as num?)?.toDouble() ?? 0,
    buttons: (json['buttons'] as num?)?.toInt() ?? 0,
    dx: (json['dx'] as num?)?.toDouble() ?? 0,
    dy: (json['dy'] as num?)?.toDouble() ?? 0,
    keyCode: (json['keyCode'] as num?)?.toInt() ?? 0,
    characters: json['characters'] as String? ?? '',
    modifiers: (json['modifiers'] as num?)?.toInt() ?? 0,
    focused: json['focused'] as bool? ?? false,
    time: (json['t'] as num?)?.toInt() ?? 0,
    instance: _instance(json),
  );

  /// What happened.
  final AudShellInputKind kind;

  /// The position from the left in points.
  final double x;

  /// The position from the top in points.
  final double y;

  /// The pressed buttons: 1 primary, 2 secondary, 4 middle.
  final int buttons;

  /// The scroll in points, positive to the right.
  final double dx;

  /// The scroll in points, positive down.
  final double dy;

  /// The macOS key code of a key event.
  final int keyCode;

  /// The characters of a key event.
  final String characters;

  /// The modifier flags of the event.
  final int modifiers;

  /// Whether the view has the focus, for [AudShellInputKind.focus].
  final bool focused;

  /// The time stamp of the event in mach time nanoseconds.
  final int time;

  @override
  Map<String, Object?> toJson() => {
    'type': 'input',
    'instance': instance,
    'kind': kind.name,
    'x': x,
    'y': y,
    'buttons': buttons,
    'dx': dx,
    'dy': dy,
    'keyCode': keyCode,
    'characters': characters,
    'modifiers': modifiers,
    'focused': focused,
    't': time,
  };
}

// #############################################################################
/// Where the plugin's view is: its frame on the screen in AppKit's global
/// coordinates (points, origin bottom left), the backing scale of its
/// screen, the number of the host's window and whether the view shows.
/// The plugin sends it when the editor starts and whenever the view or
/// the host's window moves, resizes, changes the screen or hides.
final class AudShellPlace extends AudShellMessage {
  /// Creates the message.
  const AudShellPlace({
    super.instance,
    required this.x,
    required this.y,
    required this.width,
    required this.height,
    required this.scale,
    this.window = 0,
    this.visible = true,
  });

  /// A message from [toJson].
  factory AudShellPlace.fromJson(Map<String, Object?> json) => AudShellPlace(
    x: _double(json, 'x'),
    y: _double(json, 'y'),
    width: _double(json, 'width'),
    height: _double(json, 'height'),
    scale: _double(json, 'scale'),
    window: (json['window'] as num?)?.toInt() ?? 0,
    visible: json['visible'] as bool? ?? true,
    instance: _instance(json),
  );

  /// The left edge on the screen.
  final double x;

  /// The bottom edge on the screen.
  final double y;

  /// The width in points.
  final double width;

  /// The height in points.
  final double height;

  /// The backing scale of the screen.
  final double scale;

  /// The window number of the host's window, or 0.
  final int window;

  /// Whether the view shows: false while the host's window is minimized or
  /// on another space.
  final bool visible;

  @override
  Map<String, Object?> toJson() => {
    'type': 'place',
    'instance': instance,
    'x': x,
    'y': y,
    'width': width,
    'height': height,
    'scale': scale,
    'window': window,
    'visible': visible,
  };
}

// #############################################################################
/// The cursor the editor wants over the plugin's view.
final class AudShellCursor extends AudShellMessage {
  /// Creates the message.
  const AudShellCursor(this.kind, {super.instance});

  /// A message from [toJson].
  factory AudShellCursor.fromJson(Map<String, Object?> json) =>
      AudShellCursor(json['kind']! as String, instance: _instance(json));

  /// The kind of Flutter's system cursors, e.g. `basic` or `resizeUpDown`.
  final String kind;

  @override
  Map<String, Object?> toJson() => {
    'type': 'cursor',
    'instance': instance,
    'kind': kind,
  };
}

// #############################################################################
/// A measurement record of the editor that the plugin writes into its probe
/// log, so that one file holds both processes' records.
final class AudShellProbe extends AudShellMessage {
  /// Creates the message.
  const AudShellProbe(this.kind, this.fields, {super.instance});

  /// A message from [toJson].
  factory AudShellProbe.fromJson(Map<String, Object?> json) => AudShellProbe(
    json['kind']! as String,
    Map<String, Object?>.from(json['fields']! as Map<String, Object?>),
    instance: _instance(json),
  );

  /// The kind of the record, e.g. `paramApplied`.
  final String kind;

  /// The fields of the record; `t` is the mach time in nanoseconds.
  final Map<String, Object?> fields;

  @override
  Map<String, Object?> toJson() => {
    'type': 'probe',
    'instance': instance,
    'kind': kind,
    'fields': fields,
  };
}

// #############################################################################
/// The plugin's view is shown again: the instance's view resumes.
final class AudShellShow extends AudShellMessage {
  /// Creates the message.
  const AudShellShow({super.instance});

  @override
  Map<String, Object?> toJson() => {'type': 'show', 'instance': instance};
}

// #############################################################################
/// The plugin's view was removed: the editor keeps the instance's view
/// warm and sends no frames for it.
final class AudShellHide extends AudShellMessage {
  /// Creates the message.
  const AudShellHide({super.instance});

  @override
  Map<String, Object?> toJson() => {'type': 'hide', 'instance': instance};
}

// #############################################################################
/// The plugin instance is gone: the editor drops its view.
final class AudShellRemove extends AudShellMessage {
  /// Creates the message.
  const AudShellRemove({super.instance});

  @override
  Map<String, Object?> toJson() => {'type': 'remove', 'instance': instance};
}

// #############################################################################
/// The editor quits.
final class AudShellClose extends AudShellMessage {
  /// Creates the message.
  const AudShellClose();

  @override
  Map<String, Object?> toJson() => {'type': 'close'};
}
