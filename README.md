# aud_audio_vst3

VST3 shell of the Audanika Audio Engine over its headless host.

Part of the Audanika Audio Engine; planned in [aud_audio_pm](https://github.com/audaudio/aud_audio_pm).

## What the package holds (ticket 37)

The VST3 shell of the engine (step S18, macOS on Apple silicon and, since
ticket 38, Windows on x86-64): an
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
  realtime blocks; it writes each preset's sound as WAV on request. With
  `--editor` it shows the editor in a window that takes no focus, waits for
  its frames, clicks into it and expects the editor's notes on the plugin's
  event output and a new frame for every click - also while other
  processes keep the shared surfaces in use, during a live resize, after a
  resize without `onSize`, under a covering window, and with a held note
  when the editor is killed.
- The editor (decision plugin-003, variant S; `src/aud_vst3_editor.mm`):
  the Flutter app the configuration names under `editor`, copied into the
  bundle's `Contents/Helpers` by `build-plugin.js --editor <app>`. One
  editor process serves every instance of a plugin build in the DAW, one
  Flutter view per instance, shown through shared IOSurfaces. The plugin
  starts it with a connected socket on file descriptor 3 and finds its
  surfaces under a Mach name prefixed with the configuration's
  `appGroup`, so that a sandboxed editor reaches both (decision
  plugin-007). The editor plays MIDI through the plugin, which also sends
  it to the DAW on its event output, and chooses the plugin's preset. The
  plugin pauses the editor only while its window is invisible, minimized
  or on another Space, sends any change of position, size or scale within
  0.1 s, and ends the notes the editor holds when the editor ends. Plugin
  and editor log visibility changes, late frames and stalls to the unified
  log; `AUD_VST3_LOG=<file>` collects their lines in a test. Without
  `editor` the plugin shows the DAW's generic view.
- Windows (ticket 38, decisions plugin-008 and plugin-009): the bundle is
  an x86-64 DLL in `Contents\x86_64-win`, built by the clang++ of Visual
  Studio against the static C++ runtime; it exports only `GetPluginFactory`,
  `InitDll` and `ExitDll`, which the build checks. An app builds it into
  its own folder and links it into a VST3 folder by a junction; the plugin
  finds content and editor through `containing-folder:<path>` of
  `plugin.json`. The editor is an executable (`editor`:
  `containing-folder:<exe>`) the plugin starts with `--plugin-editor
  --socket <path> --token <hex> --instance <n> --parent <window>` for every
  open view, in a job object: it makes its Flutter view a child of the
  plugin's window and talks over a Unix domain socket in `%TEMP%`
  (`src/aud_vst3_editor_win.cpp`). The logs go to the debugger's output
  (`OutputDebugString`).
- The subset of the VST3 SDK 3.8.1 (MIT) in `src/third_party/vst3sdk`; see
  `src/third_party/NOTICES.md`.

## Dart API

`aud_audio_vst3.dart` is the editor's end of the shell protocol between the
plugin and its editor process: JSON messages, framed by `AudShellCodec`,
over the socket the plugin hands the editor as file descriptor 3
(`AudShellClient.fromFd`, read and written by `AudShellFd` through FFI,
since `dart:io` opens no inherited socket), or over a Unix domain socket
the plugin listens on (`AudShellClient.connect`).
`example/aud_audio_vst3_example.dart` runs both ends in one process.
On Windows, which hands a process no socket as a file descriptor,
`AudShellFd.open` and with it `AudShellClient.fromFd` throw an
`UnsupportedError`; the editor connects with `AudShellClient.connect`.

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

- `AudShellClient.fromFd(fd, hello)` and `AudShellClient.connect(path,
  hello)` connect and send the `AudShellHello` with the token the plugin
  started the editor with;
  `messages` carries the plugin's messages and ends when the plugin closes
  the socket, `send(message)` frames a message to the plugin, `close()`
  ends both directions.
- From the plugin: `AudShellWelcome` (the document's `AudShellParam`s, the
  editor's size and scale, the presets as `AudShellPresetInfo`s and the
  current one), `AudShellPreset` (the plugin plays another preset),
  `AudShellParamValue` (a parameter changed in the plugin),
  `AudShellInput` (an input event of the plugin's view, of an
  `AudShellInputKind`), `AudShellPlace` (where the plugin's view is on the
  screen), `AudShellShow`, `AudShellHide` and `AudShellRemove`.
- To the editor: `AudShellClose` (quit); the plugin of this package does
  not send it, it ends the connection instead.
- To the plugin: `AudShellHello`, `AudShellMidi` (MIDI 1.0 bytes the
  plugin plays and sends to the DAW), `AudShellSelectPreset`,
  `AudShellCommand` (an `AudCommand` of `aud_audio_core` with the time
  stamp of the input behind it),
  `AudShellGesture` (`AudShellGesturePhase.begin` and `end` of an
  automation edit) and `AudShellCursor`.
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
<.dart_tool/package_config.json>`, copies its editor app into the bundle
with `--editor <app>` and signs it with `--sign <identity>` (`--out`,
`--install`, `--rtsan`, `--watchdog`). `host.js` builds the
example plugin and runs the test host on it, or on the bundle it is given
(`--wav <dir>`, `--presets n`, `--realtime-seconds s`, `--editor s`
with `--snapshot <png>`, `--click x,y`, `--clicks n`, `--click-pause s`,
`--cover`, `--hold-surfaces` and `--hold-seconds s`, `--resize-steps n`,
`--reframe`, `--occlude` and `--kill-editor`). `validate.js` runs
the SDK's validator on the bundles of `build/vst3` or on the given ones.
`test-native.js` builds and runs the unit tests of the native code in
`test/native`. `reaper-test.js` tests an installed plugin in REAPER: found,
rendered offline with presets (`--render 0,13,27 --presets 28`), played
live, its preset restored with the project, its editor shown and captured
(`--plugin <name>`, `--show-editor s`).
`vendor-vst3sdk.js` vendors the subset of the VST3 SDK into
`src/third_party/vst3sdk` and writes `src/third_party/NOTICES.md`.

On Windows the scripts take clang++, lld-link and llvm-readobj from the LLVM
of Visual Studio (component "C++ Clang compiler for Windows");
`build-plugin.js --install` copies the bundle into
`%LOCALAPPDATA%\Programs\Common\VST3`, which REAPER and Cubase scan.
`build-plugin.js`, `validate.js`, `test-native.js`, `reaper-test.js` and
`vendor-vst3sdk.js` run there; the test host (`host.js`), the
RealtimeSanitizer and `--editor` are macOS only.

