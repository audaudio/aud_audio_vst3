# aud_audio_vst3

VST3-Shell der Audanika Audio Engine über ihrem Headless Host.

Teil der Audanika Audio Engine; geplant in [aud_audio_pm](https://github.com/audaudio/aud_audio_pm).

## Was das Paket enthält (Ticket 37)

Die VST3-Shell der Engine (Schritt S18, macOS auf Apple Silicon): ein
Instrument-Plugin über dem Headless Host von `aud_audio_graph`, das eine
App mit drei Dateien konfiguriert - `plugin.json`, ein Graph-Dokument und
seine Presets ([doc/plugin-bundle.md](doc/plugin-bundle.md)) - und mit den
Node-Paketen baut, die sie nennt.

- Das Plugin (`src/`): ein Single-Component-Instrument, das das
  Graph-Dokument der App mit `aud_host_render` rendert.
  - Presets: die Programmliste und der gestufte Parameter "Preset"; ein
    Preset wendet seine Node-Presets auf einem Control-Thread an.
  - Parameter: die Graph-Parameter, die die Konfiguration aufführt, unter
    ihren stabilen Ids, und Regler, die beim Bewegen MIDI-Control-Changes
    senden.
  - MIDI: Noten und Poly Pressure der DAW und über `IMidiMapping` ihre
    Control Changes, Channel Pressure und Pitch Bend auf 16 Kanälen
    erreichen den Event-Eingang des Graphen zu ihren Sample-Offsets; der
    Referenz-Node `aud.graph.channel_split` schickt jeden Kanal zu seinem
    Node.
  - Transport: Tempo, Taktart und Position der DAW; steht die DAW, läuft
    der Transport in ihrem Tempo weiter, damit tempo-synchrone Modulation
    in Bewegung bleibt.
  - Zustand: das Preset, die Parameterwerte und die bewegten Regler als
    JSON, nie ein Pfad. Offline-Rendering wartet auf das Instrument eines
    Presets.
  - Assets: der Content der App, in der das Plugin liegt, gefunden über den
    Link, über den eine DAW es lädt, oder über die Bundle-Id der App.
  - Symbol-Hygiene (plugin-004): das Bundle exportiert nur die drei
    VST3-Einstiegspunkte; die Node-Pakete sind mit versteckten Symbolen
    hineinkompiliert.
- Der Build (`scripts/build-plugin.js`): das eingebundene SDK, der Graph,
  die Node-Pakete nach Rezepten gemäß ihren Build-Hooks (sfizz und
  QuickJS-ng aus ihren Manifesten), `Info.plist`, `moduleinfo.json`, die
  Notices, eine Signatur mit Hardened Runtime.
- Das Beispiel-Plugin (`example/plugin`): ein Oszillator durch ein Filter,
  die eigenen Nodes des Graphen, für die Tests.
- Der Test-Host (`test/host/aud_vst3_host.mm`): lädt ein Bundle wie eine
  DAW und prüft, dass jedes Preset offline klingt, die Programmliste, das
  MIDI-Mapping, den Zustand über zwei Instanzen und die Zeit von
  Echtzeit-Blöcken; auf Wunsch schreibt er den Klang jedes Presets als WAV.
  Mit `--editor` zeigt er den Editor in einem Fenster, das keinen Fokus
  nimmt, wartet auf seine Frames, klickt hinein und erwartet die Noten des
  Editors am Event-Ausgang des Plugins und für jeden Klick einen neuen
  Frame - auch wenn andere Prozesse die geteilten Surfaces in Benutzung
  halten, während eines Live-Resize, nach einer Größenänderung ohne
  `onSize`, unter einem verdeckenden Fenster und mit einer gehaltenen Note,
  wenn der Editor beendet wird.
- Der Editor (Entscheidung plugin-003, Variante S;
  `src/aud_vst3_editor.mm`): die Flutter-App, die die Konfiguration unter
  `editor` nennt, von `build-plugin.js --editor <app>` in
  `Contents/Helpers` des Bundles kopiert. Ein Editor-Prozess bedient jede
  Instanz eines Plugin-Builds in der DAW, eine Flutter-View je Instanz,
  gezeigt über geteilte IOSurfaces. Das Plugin startet ihn mit einem
  verbundenen Socket als File-Deskriptor 3 und findet seine Surfaces unter
  einem Mach-Namen mit dem `appGroup` der Konfiguration als Präfix, damit
  ein sandboxed Editor beide erreicht (Entscheidung plugin-007). Der Editor
  spielt MIDI über das Plugin, das es auch an seinem Event-Ausgang an die
  DAW sendet, und wählt das Preset des Plugins. Das Plugin pausiert den
  Editor nur, solange sein Fenster unsichtbar, minimiert oder auf einem
  anderen Space ist, sendet jede Änderung von Position, Größe oder Skalierung
  innerhalb von 0,1 s und beendet die Noten, die der Editor hält, wenn der
  Editor endet. Plugin und Editor schreiben Sichtbarkeitswechsel, verspätete
  Frames und Stockungen ins Unified Log; `AUD_VST3_LOG=<datei>` sammelt ihre
  Zeilen in einem Test. Ohne `editor` zeigt das Plugin die generische View
  der DAW.
- Die Teilmenge des VST3 SDK 3.8.1 (MIT) in `src/third_party/vst3sdk`;
  siehe `src/third_party/NOTICES.md`.

## Dart-API

`aud_audio_vst3.dart` ist das Ende des Editors im Shell-Protokoll zwischen
dem Plugin und seinem Editor-Prozess: JSON-Nachrichten, von
`AudShellCodec` gerahmt, über das Socket, das das Plugin dem Editor als
File-Deskriptor 3 übergibt (`AudShellClient.fromFd`, gelesen und
geschrieben von `AudShellFd` über FFI, da `dart:io` kein geerbtes Socket
öffnet), oder über ein Unix-Domain-Socket, auf dem das Plugin lauscht
(`AudShellClient.connect`). `example/aud_audio_vst3_example.dart` spielt
beide Enden in einem Prozess durch.

```dart
import 'dart:io';

import 'package:aud_audio_core/aud_audio_core.dart';
import 'package:aud_audio_vst3/aud_audio_vst3.dart';

final editor = await AudShellClient.connect(         // sendet das Hello
  socketPath,
  AudShellHello(token: token, instance: 1, pid: pid),
);
final welcome = await editor.messages.first;         // AudShellWelcome
editor.send(                                         // ein Knopf bewegt
  const AudShellCommand(AudSetParamCommand(node: 1, paramIndex: 0, value: 440)),
);
await editor.close();                                // beide Richtungen zugleich
```

- `AudShellClient.fromFd(fd, hello)` und `AudShellClient.connect(path,
  hello)` verbinden sich und senden das `AudShellHello` mit dem Token, mit
  dem das Plugin den Editor gestartet hat; `messages` liefert die
  Nachrichten des Plugins und endet, wenn das Plugin das Socket schließt,
  `send(message)` schickt eine Nachricht gerahmt an das Plugin, `close()`
  beendet beide Richtungen.
- Vom Plugin: `AudShellWelcome` (die `AudShellParam`s des Dokuments, Größe
  und Skalierung des Editors, die Presets als `AudShellPresetInfo`s und das
  aktuelle), `AudShellPreset` (das Plugin spielt ein anderes Preset),
  `AudShellParamValue` (ein Parameter hat sich im Plugin geändert),
  `AudShellInput` (ein Eingabe-Ereignis der View des Plugins, von einer
  `AudShellInputKind`), `AudShellPlace` (wo die View des Plugins auf dem
  Bildschirm liegt), `AudShellShow`, `AudShellHide` und `AudShellRemove`.
- An den Editor: `AudShellClose` (beenden); das Plugin dieses Pakets
  sendet es nicht, es beendet stattdessen die Verbindung.
- An das Plugin: `AudShellHello`, `AudShellMidi` (MIDI-1.0-Bytes, die das
  Plugin spielt und an die DAW sendet), `AudShellSelectPreset`,
  `AudShellCommand` (ein `AudCommand` aus `aud_audio_core` mit dem
  Zeitstempel der Eingabe dahinter), `AudShellGesture`
  (`AudShellGesturePhase.begin` und `end` einer Automations-Bearbeitung)
  und `AudShellCursor`.
- Jede Nachricht nennt die Plugin-Instanz (`instance`), zu der sie gehört;
  `AudShellMessage.fromJson` liest, was `toJson` schreibt.
- `AudShellCodec.encode(message)` rahmt eine Nachricht: eine 4-Byte-Länge
  in Little Endian, dann so viele Bytes UTF-8-JSON, höchstens
  `AudShellCodec.maxFrame` (16 MiB). `AudShellCodec.decoder()` zerlegt
  einen Byte-Strom in Nachrichten und beendet ihn mit einer
  `FormatException` bei einem größeren Rahmen oder bei Text, der keine
  Nachricht ist. Die Seite des Plugins (`src/aud_vst3_socket.cpp`) rahmt
  genauso.
- `audShellProtocolVersion` ist die Protokollversion, die Hello und
  Welcome tragen, `audAudioVst3Version` die Version des Pakets.

## Bauen und testen

```bash
node scripts/build-plugin.js
node scripts/host.js
node scripts/validate.js
node scripts/test-native.js
```

`build-plugin.js` baut das Beispiel-Plugin nach `build/vst3`; eine App baut
ihr eigenes mit `--config <plugin.json> --package-config
<.dart_tool/package_config.json>`, kopiert ihre Editor-App mit
`--editor <app>` ins Bundle und signiert es mit `--sign <identität>`
(`--out`, `--install`, `--rtsan`, `--watchdog`). `host.js` baut das
Beispiel-Plugin und startet den Test-Host darauf oder auf dem Bundle, das
es bekommt (`--wav <ordner>`, `--presets n`, `--realtime-seconds s`,
`--editor s` mit `--snapshot <png>`, `--click x,y`, `--clicks n`,
`--click-pause s`, `--cover`, `--hold-surfaces` und `--hold-seconds s`,
`--resize-steps n`, `--reframe`, `--occlude` und `--kill-editor`).
`validate.js` startet den Validator des SDK auf den Bundles in
`build/vst3` oder auf den angegebenen. `test-native.js` baut und startet
die Unit-Tests des nativen Codes in `test/native`. `reaper-test.js` testet
ein installiertes Plugin in REAPER: gefunden, offline mit Presets
gerendert (`--render 0,13,27 --presets 28`), live gespielt, sein Preset
mit dem Projekt wiederhergestellt, sein Editor gezeigt und aufgenommen
(`--plugin <name>`, `--show-editor s`). `vendor-vst3sdk.js` übernimmt die
Teilmenge des VST3 SDK nach `src/third_party/vst3sdk` und schreibt
`src/third_party/NOTICES.md`.
