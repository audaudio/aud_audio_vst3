# aud_audio_vst3

VST3 shell of the Audanika Audio Engine over its headless host.

Part of the Audanika Audio Engine; planned in [aud_audio_pm](https://github.com/audaudio/aud_audio_pm).

## What the package holds (ticket 37)

The VST3 shell of the engine (step S18, macOS on Apple silicon): an
instrument plugin over the headless host of `aud_audio_graph` that an app
configures with three files - `plugin.json`, a graph document and its
presets ([doc/plugin-bundle.md](doc/plugin-bundle.md)) - and builds with
the node packages it names linked in.

- The plugin (`src/`): a single-component instrument that renders the
  app's graph document through `aud_host_render`.
  - Presets: the program list and the stepped parameter "Preset"; a preset
    applies its node presets on a control thread.
  - Parameters: the graph parameters the configuration lists, under their
    stable ids, and controls that send MIDI control changes when they move.
  - MIDI: the DAW's notes and poly pressure, and through `IMidiMapping`
    its control changes, channel pressure and pitch bend on 16 channels,
    reach the graph's event input at their sample offsets; the reference
    node `aud.graph.channel_split` sends each channel to its node.
  - Transport: the DAW's tempo, time signature and position; while the DAW
    stands the transport runs on at its tempo, so that tempo-synced
    modulation keeps moving.
  - State: the preset, the parameter values and the moved controls as JSON,
    never a path. Offline rendering waits for the instrument of a preset.
  - Assets: the content of the app the plugin ships in, found through the
    link a DAW loads it by, or through the app's bundle id.
  - Symbol hygiene (plugin-004): the bundle exports only the three VST3
    entry points; the node packages are compiled in with hidden symbols.
- The build (`scripts/build-plugin.js`): the vendored SDK, the graph, the
  node packages by recipes after their build hooks (sfizz and QuickJS-ng
  from their manifests), `Info.plist`, `moduleinfo.json`, the notices, a
  signature with the hardened runtime.
- The example plugin (`example/plugin`): an oscillator through a filter,
  the graph's own nodes, for the tests.
- The test host (`test/host/aud_vst3_host.mm`): loads a bundle as a DAW
  does and checks that every preset sounds offline, the program list,
  the MIDI mapping, the state across two instances and the time of
  realtime blocks; it writes each preset's sound as WAV on request.
- The editor of the spike S0-plugin-ui (ticket 24, decision plugin-003) -
  a Flutter app in a process of its own, shown through shared IOSurfaces
  (`src/aud_vst3_remote_view.mm`, `editor/`) - is not built until the
  editor of ticket 37 replaces it; the plugin shows the DAW's generic view.
- The subset of the VST3 SDK 3.8.1 (MIT) in `src/third_party/vst3sdk`; see
  `src/third_party/NOTICES.md`.

## Dart API

The protocol of the spike's editor; the editor of ticket 37 builds on it.

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

## Build and test

```bash
node scripts/build-plugin.js
node scripts/host.js
node scripts/validate.js
node scripts/test-native.js
```

`build-plugin.js` builds the example plugin into `build/vst3`; an app
builds its own with `--config <plugin.json> --package-config
<.dart_tool/package_config.json>` and signs it with `--sign <identity>`
(`--out`, `--install`, `--rtsan`, `--watchdog`). `host.js` builds the
example plugin and runs the test host on it, or on the bundle it is given
(`--wav <dir>`, `--presets n`, `--realtime-seconds s`). `validate.js` runs
the SDK's validator on the bundles of `build/vst3` or on the given ones.
`test-native.js` builds and runs the unit tests of the native code in
`test/native`. `reaper-test.js` tests an installed plugin in REAPER: found,
rendered offline with presets (`--render 0,13,27 --presets 28`), played
live, its preset restored with the project (`--plugin <name>`).
`vendor-vst3sdk.js` vendors the subset of the VST3 SDK into
`src/third_party/vst3sdk` and writes `src/third_party/NOTICES.md`.

Until `aud_audio_ui_controls` 0.1.0 is released, the editor builds against
the checkout of `aud_audio_ui_controls` next to this repo
(`editor/pubspec_overrides.yaml`).
