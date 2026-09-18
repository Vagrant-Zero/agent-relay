import AppKit
import AgentMeterCore
import Darwin

signal(SIGPIPE, SIG_IGN)
let application = NSApplication.shared
if CommandLine.arguments.contains("--verify-quota-layout") {
    do {
        let manager = ManagerController(store: try Store(), persistWindowFrame: false)
        let widths = [680, 740, 1000].map { manager.quotaTrackWidths(at: NSSize(width: $0, height: 470)) }
        FileHandle.standardOutput.write(try JSONEncoder().encode(widths))
        exit(0)
    } catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
}
if CommandLine.arguments.contains("--verify-session-load") {
    do {
        let ids = try SessionsController(store: Store()).verifyInitialLoad()
        FileHandle.standardOutput.write(try JSONEncoder().encode(ids))
        exit(0)
    } catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
}
if let index = CommandLine.arguments.firstIndex(of: "--render-design"), index + 1 < CommandLine.arguments.count {
    do {
        let store = try Store()
        let url = URL(fileURLWithPath: CommandLine.arguments[index + 1])
        let dark = CommandLine.arguments.contains("--dark")
        let size = NSSize(width: CommandLine.arguments.contains("--compact") ? 680 : 740, height: CommandLine.arguments.contains("--sessions") ? 560 : 470)
        if CommandLine.arguments.contains("--appearance") {
            try SettingsController().render(to: url, dark: dark)
        } else if CommandLine.arguments.contains("--sessions") {
            try SessionsController(store: store).render(to: url, dark: dark, size: size)
        } else { try ManagerController(store: store, persistWindowFrame: false).render(to: url, dark: dark, size: size) }
    } catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
    exit(0)
}
let delegate = AppDelegate()
application.delegate = delegate
application.run()
