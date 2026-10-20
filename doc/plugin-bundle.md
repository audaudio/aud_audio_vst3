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
  //   app:<bundle id>:<path> inside the installed app with that id
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
  "editor": null
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
- **State.** JSON with the preset id, the parameter values and the values
  of the controls that moved, so that a project never holds a path of the
  machine it was saved on.
