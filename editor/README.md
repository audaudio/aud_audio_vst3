# aud_audio_vst3_editor

The Flutter editor of the aud_audio_vst3 spike (ticket 24): the knobs of
`aud_audio_ui_controls` bound to the plugin over the shell protocol. The
plugin starts it from its bundle and shows its views through shared
IOSurfaces (variants A and S) or keeps its window over the plugin's view
(F); in variant B it runs inside the plugin (`--inprocess`).
`scripts/build-plugin.js --editor` builds it into the bundles; the README
of the repo describes the variants and the build.

```bash
flutter test
```
