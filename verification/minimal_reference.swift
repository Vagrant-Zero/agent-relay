import AppKit
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
status.button?.title = "Test"
app.run()
