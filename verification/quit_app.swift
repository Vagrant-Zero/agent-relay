import AppKit
import Foundation

guard CommandLine.arguments.count == 2,
      let pid = Int32(CommandLine.arguments[1]) else {
    exit(2)
}

if let app = NSRunningApplication(processIdentifier: pid) {
    print(app.terminate() ? "quit-requested" : "quit-rejected")
} else {
    print("already-stopped")
}
