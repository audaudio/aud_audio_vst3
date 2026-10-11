// @license
// Copyright (c) Audanika. All Rights Reserved.
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import Cocoa
import FlutterMacOS

// The editor process of the aud_audio_vst3 spike (ticket 24) runs as an
// agent: no Dock icon, no menu bar, never the active app. It starts one
// Flutter engine without a view and lets Dart ask for a view per plugin
// instance (AudEditorViews); it lives as long as the plugin's socket.
//
// The app starts background-only (LSBackgroundOnly): AppKit activates an
// agent (LSUIElement) that a DAW starts directly, and the DAW, inactive,
// may close its audio device - REAPER does when its transport stops
// (ticket 24, finding). Once launched, the app may show windows as an
// accessory; that does not activate it.
@main
class AppDelegate: FlutterAppDelegate {
  private var engine: FlutterEngine?
  private var views: AudEditorViews?
  private var parentWatch: DispatchSourceProcess?

  override func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.setActivationPolicy(.accessory)
    watchParent()
    let arguments = Array(CommandLine.arguments.dropFirst())
    let project = FlutterDartProject()
    project.dartEntrypointArguments = arguments
    let engine = FlutterEngine(name: "aud_editor", project: project, allowHeadlessExecution: true)
    // Several views on one engine need multi-view, which FlutterMacOS 3.47
    // keeps private (the experimental windowing API turns it on); without
    // it the engine takes one view, the implicit one (ticket 24, finding).
    // Without it the editor takes one view and refuses a second one, which
    // the plugin logs; a Flutter that drops the selector shows up there.
    let multiView = NSSelectorFromString("enableMultiView")
    let hasMultiView = engine.responds(to: multiView)
    if hasMultiView {
      engine.perform(multiView)
    } else {
      FileHandle.standardError.write(Data("enableMultiView is missing: one view only\n".utf8))
    }
    views = AudEditorViews(engine: engine, arguments: arguments, multiView: hasMultiView)
    engine.run(withEntrypoint: nil)
    RegisterGeneratedPlugins(registry: engine)
    self.engine = engine
  }

  // The editor lives no longer than the DAW that started it: the end of
  // the socket does not reach an editor that is still starting or is hung,
  // and a DAW that quits or crashes cannot kill it any more.
  private func watchParent() {
    let parent = getppid()
    if parent <= 1 { exit(0) }
    let watch = DispatchSource.makeProcessSource(
      identifier: parent, eventMask: .exit, queue: .main)
    watch.setEventHandler { exit(0) }
    watch.resume()
    parentWatch = watch
  }

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return false
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }
}
