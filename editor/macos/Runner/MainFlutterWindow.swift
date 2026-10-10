// @license
// Copyright (c) Audanika. All Rights Reserved.
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import Cocoa
import FlutterMacOS

// The window of the main nib; the editor shows nothing in it. Every view
// is a window of AudEditorViews.
class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    super.awakeFromNib()
    orderOut(nil)
  }
}

// The windows of the editor process (ticket 24), one Flutter view of the
// one engine per plugin instance; Dart asks for them on the runner channel.
//
// - surface mode (A, S): a window is transparent, ignores the mouse and
//   lies over the plugin's view, so that Flutter renders at that screen's
//   scale and refresh rate; its AudEditorBridge copies the frames into the
//   surfaces the plugin shows, and the input arrives over the socket.
// - follow mode (F): a window is visible, borderless and kept above the
//   host's window over the plugin's view; it takes its own input without
//   activating the editor app (a non-activating panel).
//
// A view renders only while the plugin shows it (show and hide) and its
// window can be seen (place's visible): a minimized or covered host window
// costs nothing.
final class AudEditorViews {
  private struct View {
    let window: NSWindow
    let controller: FlutterViewController
    let bridge: AudEditorBridge?
    var shown = false
    var onScreen = false
  }

  private let engine: FlutterEngine
  private let multiView: Bool
  private let follow: Bool
  private let service: String?
  private var views: [Int: View] = [:]
  private let channel: FlutterMethodChannel

  init(engine: FlutterEngine, arguments: [String], multiView: Bool) {
    self.engine = engine
    self.multiView = multiView
    follow = AudEditorViews.value(of: "--mode", in: arguments) == "follow"
    service = AudEditorViews.value(of: "--mach", in: arguments)
    channel = FlutterMethodChannel(
      name: "aud_vst3_editor/runner", binaryMessenger: engine.binaryMessenger)
    channel.setMethodCallHandler { [weak self] call, result in
      self?.handle(call, result: result)
    }
  }

  private func handle(_ call: FlutterMethodCall, result: FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    let instance = args["instance"] as? Int ?? 0
    switch call.method {
    case "addView":
      result(addView(instance: instance, args: args))
    case "place":
      place(instance: instance, args: args)
      result(nil)
    case "visible":
      let visible = args["visible"] as? Bool ?? true
      if var view = views[instance] {
        view.shown = visible
        views[instance] = view
        update(view, instance: instance)
        if follow && !visible { view.window.orderOut(nil) }
      }
      result(nil)
    case "removeView":
      if let view = views.removeValue(forKey: instance) {
        view.bridge?.stop()
        view.window.contentViewController = nil
        view.window.close()
      }
      result(nil)
    case "quit":
      result(nil)
      for view in views.values { view.bridge?.stop() }
      NSApp.terminate(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  // Creates the view of `instance` and returns its view id, or -1 when the
  // engine cannot take another view (no multi-view).
  private func addView(instance: Int, args: [String: Any]) -> Int {
    if let view = views[instance] { return Int(view.controller.viewIdentifier) }
    if !multiView && !views.isEmpty { return -1 }
    let width = args["width"] as? Double ?? 620
    let height = args["height"] as? Double ?? 220
    let window = AudEditorWindow(
      contentRect: NSRect(x: 0, y: 0, width: width, height: height),
      styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    window.follow = follow
    window.isFloatingPanel = false
    window.hidesOnDeactivate = false
    window.becomesKeyOnlyIfNeeded = false
    window.isReleasedWhenClosed = false
    window.collectionBehavior = [.transient, .ignoresCycle, .fullScreenAuxiliary]
    window.hasShadow = false
    window.alphaValue = follow ? 1 : 0
    window.ignoresMouseEvents = !follow
    let controller = FlutterViewController(engine: engine, nibName: nil, bundle: nil)
    window.contentViewController = controller
    window.setContentSize(NSSize(width: width, height: height))
    var bridge: AudEditorBridge?
    if !follow, let service = service, let contentView = window.contentView {
      bridge = AudEditorBridge(
        serviceName: service, contentView: contentView, instance: UInt32(instance))
      bridge?.paused = true
      if bridge == nil {
        NSLog("aud_editor: view %d has no Mach channel to the plugin (%@)", instance, service)
      }
    }
    // A surface window renders transparent from the start; a follow window
    // shows once the first place has put it over the plugin's view.
    if !follow { window.orderFront(nil) }
    views[instance] = View(window: window, controller: controller, bridge: bridge)
    return Int(controller.viewIdentifier)
  }

  private func update(_ view: View, instance: Int) {
    let paused = !(view.shown && view.onScreen)
    guard let bridge = view.bridge, bridge.paused != paused else { return }
    bridge.paused = paused
    // The editor log tells why a view renders or not.
    NSLog(
      "aud_editor: view %d %@ (shown %@, on screen %@, own window %@)", instance,
      paused ? "pauses" : "renders", view.shown ? "yes" : "no", view.onScreen ? "yes" : "no",
      view.window.occlusionState.contains(.visible) ? "visible" : "occluded")
  }

  private func place(instance: Int, args: [String: Any]) {
    guard var view = views[instance] else { return }
    let window = view.window
    let x = args["x"] as? Double ?? window.frame.origin.x
    let y = args["y"] as? Double ?? window.frame.origin.y
    let width = args["width"] as? Double ?? window.frame.size.width
    let height = args["height"] as? Double ?? window.frame.size.height
    window.setFrame(NSRect(x: x, y: y, width: width, height: height), display: true)
    let visible = args["visible"] as? Bool ?? true
    view.onScreen = visible
    views[instance] = view
    update(view, instance: instance)
    guard follow else { return }
    if visible, let host = args["window"] as? Int, host > 0 {
      window.order(.above, relativeTo: host)
    } else if !visible {
      window.orderOut(nil)
    }
  }

  private static func value(of option: String, in arguments: [String]) -> String? {
    guard let index = arguments.firstIndex(of: option), index + 1 < arguments.count else {
      return nil
    }
    return arguments[index + 1]
  }
}

// A borderless panel that takes the keyboard only in follow mode, without
// activating the editor app: the DAW stays the active app, which REAPER
// needs to keep its audio device open while its transport stops.
final class AudEditorWindow: NSPanel {
  var follow = false
  override var canBecomeKey: Bool { follow }
  override var canBecomeMain: Bool { false }
}
