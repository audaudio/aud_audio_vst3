# aud_audio_vst3

VST3 shell of the Audanika Audio Engine over its headless host.

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
  Rahmen-Codec und `AudShellClient` über ein Unix-Domain-Socket.
- Die Editor-App (`editor/`): `AudParamKnob`s aus `aud_audio_ui_controls`,
  an eine Socket-Senke gebunden.
- Die Teilmenge des VST3 SDK 3.8.1 (MIT) in `src/third_party/vst3sdk`;
  siehe `src/third_party/NOTICES.md`.

## Bauen und messen

```bash
node scripts/build-plugin.js --variant S --editor --install
node scripts/validate.js
node scripts/spike-host.js --plugin build/vst3/AudSpikeS1.vst3 --scenario test
node scripts/reaper-series.js --only "^open"
```

`build-plugin.js` baut die Bundles mit clang nach `build/vst3`
(`--variant`, `--flavor 2` gegen graph 0.3.0, `--no-hygiene`, `--rtsan`,
`--watchdog`, `--flutter <sdk>`). `spike-host.js` startet einen Test-Host
mit den Szenarien des Spikes, `reaper.js` und `reaper-series.js` spielen
sie in REAPER, und `analyze-probe.js` fasst die Messpunkte zusammen, die
die Plugins nach `~/Library/Logs/aud_audio_vst3` schreiben.
