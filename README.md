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
  and `AudShellClient` over a Unix domain socket.
- The editor app (`editor/`): `AudParamKnob`s of `aud_audio_ui_controls`
  bound to a socket sink.
- The subset of the VST3 SDK 3.8.1 (MIT) in `src/third_party/vst3sdk`; see
  `src/third_party/NOTICES.md`.

## Build and measure

```bash
node scripts/build-plugin.js --variant S --editor --install
node scripts/validate.js
node scripts/spike-host.js --plugin build/vst3/AudSpikeS1.vst3 --scenario test
node scripts/reaper-series.js --only "^open"
```

`build-plugin.js` builds the bundles with clang into `build/vst3`
(`--variant`, `--flavor 2` against graph 0.3.0, `--no-hygiene`, `--rtsan`,
`--watchdog`, `--flutter <sdk>`). `spike-host.js` runs a test host with the
scenarios of the spike, `reaper.js` and `reaper-series.js` run them in
REAPER, and `analyze-probe.js` summarizes the probes the plugins write to
`~/Library/Logs/aud_audio_vst3`.
