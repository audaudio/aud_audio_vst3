// @license
// Copyright (c) Audanika. All Rights Reserved.
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'package:aud_audio_ui_controls/aud_audio_ui_controls.dart';
import 'package:aud_audio_vst3/aud_audio_vst3.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import 'aud_editor_layout.dart';

// #############################################################################
/// The spec of a parameter of the plugin, for its control.
AudParamSpec audSpecOf(AudShellParam param) => AudParamSpec(
  address: AudParamAddress(param.nodeId, param.paramId),
  min: param.min,
  max: param.max,
  defaultValue: param.defaultValue,
  logarithmic: param.logarithmic,
  steps: param.steps,
  name: param.name,
  unit: param.unit,
);

// #############################################################################
/// The editor: the knobs of [AudEditorLayout.knobs], bound to the plugin's
/// parameters, and the output meter. No Material: the editor keeps to the
/// widgets layer.
class AudEditorApp extends StatefulWidget {
  // ...........................................................................
  /// Creates the editor.
  ///
  /// - [params] the plugin's parameters
  /// - [sink] where the knobs' edits go
  /// - [meter] the output peak
  /// - [onCursor] the cursor the editor wants over the plugin's view
  const AudEditorApp({
    super.key,
    required this.params,
    required this.sink,
    required this.meter,
    this.onCursor,
  });

  // ...........................................................................
  /// The plugin's parameters.
  final List<AudShellParam> params;

  // ...........................................................................
  /// Where the knobs' edits go.
  final AudParamSink sink;

  // ...........................................................................
  /// The output peak.
  final ValueListenable<double> meter;

  // ...........................................................................
  /// The cursor the editor wants over the plugin's view.
  final void Function(String kind)? onCursor;

  @override
  State<AudEditorApp> createState() => _AudEditorAppState();
}

// #############################################################################
class _AudEditorAppState extends State<AudEditorApp> {
  late final List<AudParamBinding?> _bindings = [
    for (final (nodeId, paramId, _) in AudEditorLayout.knobs)
      _bind(nodeId, paramId),
  ];

  AudParamBinding? _bind(String nodeId, String paramId) {
    for (final param in widget.params) {
      if (param.nodeId == nodeId && param.paramId == paramId) {
        return AudParamBinding(
          sink: widget.sink,
          spec: audSpecOf(param),
          initial: param.value,
        );
      }
    }
    return null;
  }

  @override
  void dispose() {
    for (final binding in _bindings) {
      binding?.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    const meterTop = AudEditorLayout.knobTop - 20;
    const meterHeight =
        AudEditorLayout.height - 2 * AudEditorLayout.knobTop + 40;
    return Directionality(
      textDirection: TextDirection.ltr,
      child: ColoredBox(
        color: const Color(AudEditorLayout.background),
        child: Stack(
          children: [
            for (var i = 0; i < _bindings.length; ++i)
              if (_bindings[i] != null)
                Positioned(
                  left: AudEditorLayout.knobLeftOf(i),
                  top: AudEditorLayout.knobTop,
                  child: MouseRegion(
                    cursor: SystemMouseCursors.resizeUpDown,
                    onEnter: (_) => widget.onCursor?.call('resizeUpDown'),
                    onExit: (_) => widget.onCursor?.call('basic'),
                    child: AudParamKnob(
                      binding: _bindings[i]!,
                      label: AudEditorLayout.knobs[i].$3,
                      size: AudEditorLayout.knobSize,
                    ),
                  ),
                ),
            Positioned(
              left: AudEditorLayout.meterLeft,
              top: meterTop,
              width: AudEditorLayout.meterWidth,
              height: meterHeight,
              child: ValueListenableBuilder<double>(
                valueListenable: widget.meter,
                builder: (context, peak, _) =>
                    CustomPaint(painter: _MeterPainter(peak.clamp(0.0, 1.0))),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// #############################################################################
class _MeterPainter extends CustomPainter {
  const _MeterPainter(this.level);

  final double level;

  @override
  void paint(Canvas canvas, Size size) {
    canvas
      ..drawRect(Offset.zero & size, Paint()..color = const Color(0xFF33383F))
      ..drawRect(
        Rect.fromLTWH(
          0,
          size.height * (1 - level),
          size.width,
          size.height * level,
        ),
        Paint()..color = const Color(0xFF59D973),
      );
  }

  @override
  bool shouldRepaint(_MeterPainter oldDelegate) => oldDelegate.level != level;
}
