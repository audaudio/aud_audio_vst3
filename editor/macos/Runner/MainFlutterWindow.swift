// @license
// Copyright (c) Audanika. All Rights Reserved.
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import Cocoa

// The window of the main nib; the editor shows nothing in it. Every view
// is a window of AudEditorViews.
class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    super.awakeFromNib()
    orderOut(nil)
  }
}
