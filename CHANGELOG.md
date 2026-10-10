# Changelog

## Unreleased

### Fixed

- Spike a Flutter editor in a VST3 plugin (ticket 24)

Add the VST3 plugin over the headless host with the editor variants A, S, F, B, C and D

Vendor the subset of the VST3 SDK 3.8.1 with its notices, copied into every bundle

Hide every symbol but the VST3 entry points; create Objective-C classes at run time

Add the shell protocol and its socket client in Dart, with a protocol demo as the example

Add the Flutter editor app, shown through shared IOSurfaces, with tests of its sink and input

Add the build, validator, test host, probe and REAPER scripts

Fix the code review's findings in the threading, the IPC and the editor's lifecycle

Depend on aud_audio_core and aud_audio_graph 0.4.0; drop the template's FFI sample

## 0.0.2 - 2026-10-08

### Added

- Initial boilerplate

### Changed

- Record the gg commit state
- Set up GitHub repo settings and branch rules
- Update dev dependencies
