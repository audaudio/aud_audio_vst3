# Changelog

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
