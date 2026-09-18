import AppKit
import AgentMeterCore
let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
defer { try? FileManager.default.removeItem(at: root) }
let store = try Store(root: root)
var registry = Registry()
var account = Account(alias: "Test", email: "test@example.invalid", plan: "pro", profilePath: root.path, managed: false)
let decoder = JSONDecoder()
account.quota = try decoder.decode(QuotaSnapshot.self, from: Data("{\"fetchedAt\":0,\"resetCards\":2,\"primary\":{\"usedPercent\":20,\"windowDurationMins\":300}}".utf8))
account.quota?.fetchedAt = Date()
registry.accounts = [account]; registry.selectedID = account.id
func save() throws { try JSONEncoder().encode(registry).write(to: store.registryURL) }
try save()
let manager = ManagerController(store: store, persistWindowFrame: false)
func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
let main = app.windows.first { $0.title == "Agent Relay" }!
func card() -> NSView { descendants(main.contentView!).first { String(describing: type(of: $0)) == "AccountRowView" }! }
let original = card()
for _ in 0..<60 {
    registry.accounts[0].quota?.fetchedAt = Date()
    try save(); manager.reload()
    precondition(card() === original, "Unchanged quota must reuse row")
}
registry.accounts[0].quota?.primary?.usedPercent = 40
try save(); manager.reload()
precondition(card() !== original, "Changed quota must redraw row")
weak var weakSettings: SettingsController?
weak var weakSessions: SessionsController?
autoreleasepool {
    var settings: SettingsController? = SettingsController()
    weakSettings = settings
    settings?.onClose = { settings = nil }
    app.windows.first { $0.title == "设置" }!.close()
    precondition(settings == nil)
    var sessions: SessionsController? = SessionsController(store: store)
    weakSessions = sessions
    sessions?.onClose = { sessions = nil }
    app.windows.first { $0.title == "本地会话" }!.close()
    precondition(sessions == nil)
}
precondition(weakSettings == nil, "Settings controller retained after event pool drains")
precondition(weakSessions == nil, "Sessions controller retained after event pool drains")
print("60 unchanged refreshes reuse rows; changed quota redraws; closed controllers released")
