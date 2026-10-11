# aud_audio_vst3

VST3-Shell der Audanika Audio Engine über ihrem Headless Host.

Teil der Audanika Audio Engine; geplant in [aud_audio_pm](https://github.com/audaudio/aud_audio_pm).

## Was das Paket enthält (0.1.0, Ticket 24)

Der Spike S0-plugin-ui: ein VST3-Plugin für macOS auf Apple Silicon über
dem Headless Host von `aud_audio_graph`, mit einem Flutter-Editor. Die
Entscheidung plugin-003 stützt sich auf seine Messungen; die Shell selbst
ist Schritt S18.

- Das Plugin (`src/`): ein Single-Component-Effekt, der ein
  Graph-Dokument aus seinem Bundle mit `aud_host_render` rendert, mit einem
  VST3-Parameter je Graph-Parameter unter seiner stabilen Id und dem
  Dokument als Zustand. Der Headless Host läuft auf einem Control-Thread;
  der Audio-Thread rendert nur. Den Editor gibt es in sechs Varianten:
  - A: eine Flutter-App in einem eigenen Prozess je Editor, gezeigt über
    geteilte IOSurfaces, die Eingaben über ein Unix-Domain-Socket
    weitergereicht
  - S: wie A, ein Editor-Prozess für alle Editoren eines Plugin-Builds
  - F: wie A, das eigene Fenster des Editors folgt der View des Plugins
  - B: Flutter im DAW-Prozess, aus einer umbenannten Kopie des Frameworks
  - C: eine native View; D: die generische View des Hosts
- Symbol-Hygiene: das Bundle exportiert nur die drei VST3-Einstiegspunkte,
  und seine Objective-C-Klassen entstehen zur Laufzeit unter Namen mit
  zufälligem Suffix, sodass zwei Builds in einem DAW-Prozess nebeneinander
  laufen.
- Das Shell-Protokoll in Dart (`lib/`): `AudShellMessage`, der
  Rahmen-Codec und `AudShellClient` über ein Unix-Domain-Socket; siehe
  [Dart-API](#dart-api).
- Die Editor-App (`editor/`): `AudParamKnob`s aus `aud_audio_ui_controls`,
  über `AudShellParamSink` an das Plugin gebunden: über das Socket in A, S
  und F, über einen Method-Channel in B (`--inprocess`).
- Die Teilmenge des VST3 SDK 3.8.1 (MIT) in `src/third_party/vst3sdk`;
  siehe `src/third_party/NOTICES.md`.

## Dart-API

`aud_audio_vst3.dart` ist das Ende des Editors im Shell-Protokoll zwischen
dem Plugin und seinem Editor-Prozess: JSON-Nachrichten, von
`AudShellCodec` gerahmt, über das Unix-Domain-Socket, auf dem das Plugin
lauscht. `example/aud_audio_vst3_example.dart` spielt beide Enden in einem
Prozess durch.

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

- `AudShellClient.connect(path, hello)` verbindet sich und sendet das
  `AudShellHello` mit dem Token, mit dem das Plugin den Editor gestartet
  hat; `messages` liefert die Nachrichten des Plugins und endet, wenn das
  Plugin das Socket schließt, `send(message)` schickt eine Nachricht
  gerahmt an das Plugin, `close()` beendet beide Richtungen.
- Vom Plugin: `AudShellWelcome` (die `AudShellParam`s des Dokuments, Größe
  und Skalierung des Editors), `AudShellParamValue` (ein Parameter hat sich
  im Plugin geändert, mit seiner laufenden Nummer), `AudShellMeter`,
  `AudShellInput` (ein Eingabe-Ereignis der View des Plugins, von einer
  `AudShellInputKind`), `AudShellPlace` (wo die View des Plugins auf dem
  Bildschirm liegt), `AudShellShow`, `AudShellHide`, `AudShellRemove` und
  `AudShellClose`.
- An das Plugin: `AudShellHello`, `AudShellCommand` (ein `AudCommand` aus
  `aud_audio_core` mit dem Zeitstempel der Eingabe dahinter),
  `AudShellGesture` (`AudShellGesturePhase.begin` und `end` einer
  Automations-Bearbeitung), `AudShellCursor` und `AudShellProbe` (ein
  Messpunkt für das Probe-Log des Plugins).
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

## Bauen und messen

```bash
node scripts/vendor-vst3sdk.js
node scripts/build-plugin.js --variant S --editor --install
node scripts/validate.js
node scripts/test-native.js
node scripts/spike-host.js --plugin build/vst3/AudSpikeS1.vst3 --scenario test
node scripts/reaper-series.js --only "^open"
```

`vendor-vst3sdk.js` übernimmt die Teilmenge des VST3 SDK nach
`src/third_party/vst3sdk` und schreibt `src/third_party/NOTICES.md`
(`--sdk <checkout>`, `--tag`, `--dest`: ein Ordner direkt in
`src/third_party`). `build-plugin.js` baut die Bundles mit clang nach
`build/vst3` (`--variant`, `--flavor 2` gegen graph 0.3.0,
`--no-hygiene`, `--rtsan`, `--watchdog`, `--flutter <sdk>`).
`test-native.js` baut und startet die Unit-Tests des nativen Codes in
`test/native`. `spike-host.js` startet einen Test-Host mit den Szenarien
des Spikes,
`reaper.js` und `reaper-series.js` spielen sie in REAPER, und
`analyze-probe.js` fasst die Messpunkte zusammen, die die Plugins nach
`~/Library/Logs/aud_audio_vst3` schreiben.

Bis `aud_audio_ui_controls` 0.1.0 veröffentlicht ist, baut der Editor
gegen den Checkout von `aud_audio_ui_controls` neben diesem Repo
(`editor/pubspec_overrides.yaml`).
