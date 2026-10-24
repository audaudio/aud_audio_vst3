# The plugin bundle

What an app hands `aud_audio_vst3` to build a VST3 plugin of its own (ticket
37): one configuration, one graph document and its presets. The shell is
generic; everything that makes the plugin an instrument of the app lives in
these three files.

## Layout

```text
<Name>.vst3/Contents/
|-Info.plist
|-PkgInfo
|-MacOS/<Name>                  the shell with the node packages linked in
|-Resources/
| |-moduleinfo.json             the module info of the VST3 SDK
| |-aud_plugin/
|   |-plugin.json               the configuration
|   |-document.json             the graph document
|   |-presets.json              the presets
|-Helpers/<Editor>.app          the editor, when the configuration names one
```

On Windows (ticket 38, plugin-008) the binary is a DLL with the name of the
bundle, without `Info.plist`, `PkgInfo` and `Helpers`:

```text
<Name>.vst3\Contents\
|-x86_64-win\<Name>.vst3        the shell with the node packages linked in
|-Resources\                    moduleinfo.json, aud_plugin\, notices\
```

## plugin.json

```jsonc
{
  "schema": 1,
  // The class as the DAW lists it, and its vendor.
  "name": "Audanika",
  "vendor": "Audanika",
  "url": "https://www.audanika.com",
  "email": "mailto:info@audanika.com",
  // The version of the bundle and of the class.
  "version": "4.5.0",
  // The bundle id of the .vst3 and the class id (32 hex digits), which
  // never changes once a DAW project uses the plugin.
  "bundleId": "com.audanika.vst3",
  "classId": "0123456789ABCDEF0123456789ABCDEF",
  "subCategories": "Instrument|Synth",
  // The node packages compiled into the shell and registered with its
  // graph, in this order; the graph's own nodes are always there.
  "packages": ["aud_dsp_sampler", "aud_dsp_effects", "aud_audio_script"],
  // The graph document and the presets, next to this file.
  "document": "document.json",
  "presets": "presets.json",
  // Where the assets of the document are: the first location that exists
  // is the host's base directory.
  //   containing-app:<path>  inside the .app that holds the plugin's
  //                          resolved bundle, e.g. through a link
  //   containing-folder:<path> inside the folder that holds the
  //                          resolved bundle, e.g. the folder of a Windows
  //                          app the plugin is built into
  //   app:<bundle id>:<path> inside the installed app with that id (macOS)
  //   bundle:<path>          inside the plugin's own bundle
  "content": [
    "containing-app:Contents/Resources/content/sfz",
    "app:com.audanika:Contents/Resources/content/sfz"
  ],
  // The voice budget of aud_dsp_sampler for the process; 0 lifts it.
  "voiceBudget": 0,
  // The graph parameters the DAW sees, under their stable ids; the others
  // stay inside.
  "parameters": [
    { "node": "delay", "param": "mix", "name": "Delay Mix" },
    { "node": "reverb", "param": "mix", "name": "Reverb Mix" },
    { "node": "limiter", "param": "gain", "name": "Volume" }
  ],
  // Parameters that send a MIDI control change to the graph's event input,
  // e.g. the slider of scripts that read CC 74 of channel 1 (0 here).
  "controls": [
    { "id": "slider", "name": "Slider", "channel": 0, "cc": 74,
      "default": 0 }
  ],
  // The editor app in Contents/Helpers; null for the host's generic view.
  // On Windows the editor's executable as a location like those of
  // `content`, e.g. "containing-folder:audanika.exe".
  "editor": "Audanika Editor.app",
  // The app group the sandboxed editor is signed with: the plugin names
  // the Mach port of the editor's frames with it as prefix, the only names
  // a sandboxed process may look up.
  "appGroup": "TEAMID.com.audanika",
  // The editor's size in points when a DAW opens it, and the smallest the
  // DAW may make it.
  "editorSize": { "width": 1024, "height": 640,
                  "minWidth": 768, "minHeight": 480 }
}
```

## presets.json

```jsonc
{
  "schema": 1,
  // The preset a new instance plays.
  "default": "AUD007871_Welcome_Combi",
  "presets": [
    {
      "id": "AUD007871_Welcome_Combi",
      "name": "Welcome Combi",
      // A node preset (aud_node_preset.schema.json of aud_audio_core) per
      // node the preset sets, applied with aud_host_apply_preset; every
      // preset names the same nodes, so that a change replaces all of a
      // preset. Strings may name an asset of the document as asset:<id>.
      "nodes": {
        "channel-0": { "schema": 1, "type": "aud.sampler.sfz",
                       "strings": { "sfz_file": "asset:f12" } },
        "delay": { "schema": 1, "type": "aud.effects.stereo_delay",
                   "params": { "mix": 0.06 } }
      }
    }
  ]
}
```

The presets are the DAW's program list, in this order, and a stepped
parameter "Preset".

## document.json

A graph document of `aud_audio_graph` (`aud_graph_document.schema.json`):
its nodes carry the default preset, its `assets` table names every file a
preset names, relative to the content. The DAW's MIDI arrives at the graph's
event input (`graph`, port 0) at its sample offsets; a document that plays
different nodes per MIDI channel connects the graph to an
`aud.graph.channel_split`, whose event output n carries channel n + 1.

## What the shell does with it

- **MIDI.** Note on, note off and poly pressure of the DAW, and through
  hidden parameters of `IMidiMapping` the control changes, pitch bend and
  channel pressure of all 16 channels, become MIDI 1.0 UMP events at their
  sample offsets.
- **Transport.** The DAW's tempo and time signature always; its position
  while it plays. While it is stopped the transport runs on at the DAW's
  tempo from where it was, so that tempo-synced modulation keeps moving
  while the musician plays live.
- **Parameters.** "Preset", the listed graph parameters and the controls;
  a preset sets its values, and the DAW hears that they changed. A control
  sends its control change only when it moves: until then the values the
  preset sets hold, e.g. the start values of a combi's scripts; `default`
  is where the DAW shows it.
- **State.** JSON with the preset id, the parameter values, the values of
  the controls that moved and the settings the editor sent last
  (`AudShellSettings`, ticket 38), so that a project never holds a path of
  the machine it was saved on; every welcome hands the settings to the
  editor.
- **Editor.** One editor process per DAW process and plugin build, one
  Flutter view per instance, started with a socket pair as file descriptor
  3 and showing its frames through IOSurfaces under a Mach name with the
  `appGroup` prefix (plugin-003, plugin-007). The plugin pauses the editor
  only while its window is invisible, minimized or on another Space, sends
  any change of the view's position, size or scale, plays the editor's
  MIDI and sends it to the DAW on the event output "MIDI Out", and ends
  the notes the editor holds when the editor ends or crashes. A crashed
  editor of an open view comes back; an editor without a view quits after
  10 s. On Windows (plugin-009) an editor process serves one open view: the
  plugin starts it with `--plugin-editor --socket <path> --token <hex>
  --instance <n> --parent <window>` in a job object, and it makes its
  Flutter view a child of the plugin's window and talks over a Unix domain
  socket in `%TEMP%`.
