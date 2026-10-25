# Changelog

## Unreleased

### Changed

- Build the VST3 shell on aud_audio_plugin
- Name aud_audio_plugin and the app in README and index

## 0.3.0 - 2026-10-24

### Added

- Add the VST3 shell and its editor on Windows
- Add the editor settings to the plugin state

### Changed

- Refuse the shell socket on Windows
- Document the Windows behavior in both languages

## 0.2.0 - 2026-10-22

### Added

- Add the VST3 shell that plays an app's graph document (ticket 37)

- plugin.json, a graph document and presets of an app configure the shell

- The node packages it names are compiled in by recipes, symbols hidden

- Presets as program list, listed graph parameters, MIDI controls

- The DAW's MIDI with IMidiMapping, its transport running free when stopped

- State as JSON without paths; offline blocks wait for the loads

- A test host, an example plugin and native tests; the spike's probes go

- Add a REAPER test of an installed plugin (ticket 37)

- scripts/reaper-test.js and scripts/reaper/test.lua: found, rendered offline per preset, played live, preset restored with the project

- The REAPER scenarios of the spike go

- Add the Flutter editor of the VST3 shell (ticket 37)

- One editor process per plugin build, one Flutter view per instance (plugin-003 S)

- Socket pair on fd 3 and app group Mach names, so a sandboxed editor connects

- AudShellFd reads and writes the inherited socket through FFI

- Protocol 2: presets in the welcome, preset changes, MIDI and preset choice from the editor

- Editor MIDI plays in the graph and goes to the DAW on a MIDI output bus

- editor, appGroup and editorSize in plugin.json; build-plugin.js --editor copies the app

- AUD_VST3_LOG collects plugin and editor lines; REAPER test shows the editor

- Spike editor app and its remote view removed

- Add an editor check to the VST3 test host (ticket 37)

- --editor shows the editor in a window that takes no focus and waits for its frames

- --snapshot writes the frame as PNG, also from 10-bit extended range surfaces

- --click taps the view and expects the editor's notes on the event output

- Add frame diagnostics to the VST3 editor view (ticket 37)

- The view logs when it shows or hides, with the window's state

- A frame that reaches the view late is logged, at most once a second

- Test host: repeated clicks check that every click redraws

- Test host: --cover, --hold-surfaces and --hold-seconds as a DAW may do

- Add the release of notes the editor still holds (ticket 37)

- The plugin follows the notes the editor plays per channel and key

- When the editor ends or crashes, its notes end in the graph and the DAW

- Test host: --resize-steps resizes the view live, --kill-editor ends the editor

- Add the documentation of the editor and its checks (ticket 37)

- README.md: the editor's rules in a DAW and the test host's editor checks

- README.de.md translated anew from README.md

- doc/plugin-bundle.md: appGroup, editorSize and what the shell does with the editor

- index.jsonc: the editor in a DAW

- Add the events of a silent call to the next block

- A process call that renders nothing, as a host's parameter flush, keeps the editor's notes, the restored controls and the DAW's control changes for the next block that renders

- Add non-ASCII names, close the fd once, drop dead messages

- Preset, control and parameter names, units and values reach the DAW as UTF-16 through a small UTF-8 decoder without shared state, so that a name like Flügel shows right; a text that is no UTF-8 - overlong, a surrogate, above U+10FFFF - is read as Latin-1

- AudShellFd.close() returns the future of its first call, so that close(2) runs once and never hits a descriptor that took the number

- AudShellProbe, AudShellMeter and AudShellParamValue.sequence go: the plugin handles no probe and sends no meter or seq

- AudShellClose stays for editors that handle it, documented as a message the plugin of this package does not send


### Changed

- Follow full screen and covered windows in the editor view (ticket 37)

- Occlusion no longer hides the view: only an invisible, minimized window or another Space

- The visibility check also sends a new position, size or scale

- Full screen notifications send the place

- Test host: --reframe resizes the view without onSize, --occlude covers its window


## 0.1.0 - 2026-10-11

### Added

- Add a Flutter editor spike to the VST3 plugin (ticket 24)

- Add the VST3 plugin over the headless host with the editor variants A, S, F, B, C and D

- Vendor the subset of the VST3 SDK 3.8.1 with its notices, copied into every bundle

- Hide every symbol but the VST3 entry points; create Objective-C classes at run time

- Add the shell protocol and its socket client in Dart, with a protocol demo as the example

- Add the Flutter editor app, shown through shared IOSurfaces, with tests of its sink and input

- Add the build, validator, test host, probe and REAPER scripts

- Fix the code review's findings in the threading, the IPC and the editor's lifecycle

- Depend on aud_audio_core and aud_audio_graph 0.4.0; drop the template's FFI sample


### Fixed

- Fix paused editors and B's teardown crash in REAPER

- Check every view's visibility from the editor host's meter timer

- Keep B's view controller and engine for 200 ms after the view closes

- Log each view's place and the editor's pauses, layers and frames

- Fix the review findings of the plugin, editor and scripts

- Validate every Mach message of the editor before using its rights

- Check the writes of getState, send only to the authenticated editor and range-check the numbers of the socket

- Add native unit tests for the parameter mapping, the socket framing and the skew (scripts/test-native.js)

- Share the helpers of the editor views; doc comments, landmarks, include groups and named constants in the native code

- Let variant B use AudShellParamSink, test every editor file and make the lints strict

- Guard --dest of vendor-vst3sdk.js, check the number options of the REAPER scripts and escape the JSON of the ReaScript

- Document the Dart API, the scripts and the editor; translate the German README


## 0.0.2 - 2026-10-08

### Added

- Initial boilerplate

### Changed

- Record the gg commit state
- Set up GitHub repo settings and branch rules
- Update dev dependencies
