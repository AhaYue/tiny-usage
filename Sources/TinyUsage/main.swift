import AppKit
import TinyUsageCore

// Native menu-bar-only lifecycle. No hidden SwiftUI Settings scene or web runtime.
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
