# aud_audio_vst3

VST3 shell of the Audanika Audio Engine over its headless host.

Part of the Audanika Audio Engine; planned in [aud_audio_pm](https://github.com/audaudio/aud_audio_pm).

## What the package holds (0.1.0, ticket 24)

The spike S0-plugin-ui: a VST3 plugin for macOS on Apple silicon over the
headless host of `aud_audio_graph`, with a Flutter editor. Decision
plugin-003 rests on its measurements; the shell itself is step S18.

- The plugin (`src/`): a single-component effect that renders a graph
  document from its bundle through `aud_host_render`, with one VST3
  parameter per graph parameter under its stable id and the document as
  its state. The headless host runs on a control thread; the audio thread
  only renders. The editor comes in six variants:
  - A: a Flutter app in a process of its own per editor, shown through
    shared IOSurfaces, with the input forwarded over a Unix domain socket
  - S: like A, one editor process for every editor of a plugin build
  - F: like A, the editor's own window follows the plugin's view
  - B: Flutter in the DAW process, from a renamed copy of the framework
  - C: a native view; D: the host's generic view
- Symbol hygiene: the bundle exports only the three VST3 entry points, and
  its Objective-C classes are created at run time under names with a
  random suffix, so that two builds coexist in one DAW process.
- The shell protocol in Dart (`lib/`): `AudShellMessage`, the framing codec
  and `AudShellClient` over a Unix domain socket; see [Dart API](#dart-api).
- The editor app (`editor/`): `AudParamKnob`s of `aud_audio_ui_controls`
  bound to the plugin through `AudShellParamSink`: over the socket in A, S
  and F, over a method channel in B (`--inprocess`).
- The subset of the VST3 SDK 3.8.1 (MIT) in `src/third_party/vst3sdk`; see
  `src/third_party/NOTICES.md`.

## Dart API

`aud_audio_vst3.dart` is the editor's end of the shell protocol between the
plugin and its editor process: JSON messages, framed by `AudShellCodec`,
over the Unix domain socket the plugin listens on.
`example/aud_audio_vst3_example.dart` runs both ends in one process.

```dart
import 'dart:io';

import 'package:aud_audio_core/aud_audio_core.dart';
import 'package:aud_audio_vst3/aud_audio_vst3.dart';

final editor = await AudShellClient.connect(         // sends the hello
  socketPath,
  AudShellHello(token: token, instance: 1, pid: pid),
);
final welcome = await editor.messages.first;         // AudShellWelcome
editor.send(                                         // a knob moved
  const AudShellCommand(AudSetParamCommand(node: 1, paramIndex: 0, value: 440)),
);
await editor.close();                                // both directions at once
```

- `AudShellClient.connect(path, hello)` connects and sends the
  `AudShellHello` with the token the plugin started the editor with;
  `messages` carries the plugin's messages and ends when the plugin closes
  the socket, `send(message)` frames a message to the plugin, `close()`
  ends both directions.
- From the plugin: `AudShellWelcome` (the document's `AudShellParam`s, the
  editor's size and scale), `AudShellParamValue` (a parameter changed in
  the plugin, with its sequence number), `AudShellMeter`, `AudShellInput`
  (an input event of the plugin's view, of an `AudShellInputKind`),
  `AudShellPlace` (where the plugin's view is on the screen),
  `AudShellShow`, `AudShellHide`, `AudShellRemove` and `AudShellClose`.
- To the plugin: `AudShellHello`, `AudShellCommand` (an `AudCommand` of
  `aud_audio_core` with the time stamp of the input behind it),
  `AudShellGesture` (`AudShellGesturePhase.begin` and `end` of an
  automation edit), `AudShellCursor` and `AudShellProbe` (a measurement
  record for the plugin's probe log).
- Every message names the plugin `instance` it belongs to;
  `AudShellMessage.fromJson` reads what `toJson` writes.
- `AudShellCodec.encode(message)` frames a message: a 4-byte little-endian
  length, then that many bytes of UTF-8 JSON, at most
  `AudShellCodec.maxFrame` (16 MiB). `AudShellCodec.decoder()` splits a
  byte stream into messages and ends it with a `FormatException` on a
  larger frame or text that is no message. The plugin's side
  (`src/aud_vst3_socket.cpp`) frames the same way.
- `audShellProtocolVersion` is the protocol version hello and welcome
  carry, `audAudioVst3Version` the version of the package.

## Build and measure

```bash
node scripts/vendor-vst3sdk.js
node scripts/build-plugin.js --variant S --editor --install
node scripts/validate.js
node scripts/test-native.js
node scripts/spike-host.js --plugin build/vst3/AudSpikeS1.vst3 --scenario test
node scripts/reaper-series.js --only "^open"
```

`vendor-vst3sdk.js` vendors the subset of the VST3 SDK into
`src/third_party/vst3sdk` and writes `src/third_party/NOTICES.md`
(`--sdk <checkout>`, `--tag`, `--dest`: a folder directly inside
`src/third_party`). `build-plugin.js` builds the bundles with clang into
`build/vst3` (`--variant`, `--flavor 2` against graph 0.3.0,
`--no-hygiene`, `--rtsan`, `--watchdog`, `--flutter <sdk>`).
`test-native.js` builds and runs the unit tests of the native code in
`test/native`. `spike-host.js` runs a test host with the scenarios of the
spike,
`reaper.js` and `reaper-series.js` run them in REAPER, and
`analyze-probe.js` summarizes the probes the plugins write to
`~/Library/Logs/aud_audio_vst3`.

Until `aud_audio_ui_controls` 0.1.0 is released, the editor builds against
the checkout of `aud_audio_ui_controls` next to this repo
(`editor/pubspec_overrides.yaml`).
