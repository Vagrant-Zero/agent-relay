import AppKit
import AgentMeterCore
import Darwin

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var item: NSStatusItem?
    private var manager: ManagerController?
    private var store: Store!
    private var worker: Process?
    private var refreshTimer: Timer?
    private var refreshSchedule = QuotaRefreshSchedule()
    private var lastMessage: String?
    private var instanceFD: Int32 = -1
    private var ownsLock = false
    private var observer: NSObjectProtocol?
    private var launchingManager = false
    private var quitting = false
    private var quitTimer: Timer?
    private let lifecycleCheck = CommandLine.arguments.contains("--verify-lifecycle")
    private var commandObserver: NSObjectProtocol?
    private let requestName = Notification.Name("dev.local.agent-meter.window-request")
    private let isManager = CommandLine.arguments.contains("--manage")

    func applicationDidFinishLaunching(_ notification: Notification) {
        do { store = try Store() }
        catch { showFatal(error.localizedDescription); return }
        let lockURL = store.root.appendingPathComponent(isManager ? "window.lock" : "menu.lock")
        instanceFD = open(lockURL.path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard instanceFD >= 0, flock(instanceFD, LOCK_EX | LOCK_NB) == 0 else {
            if isManager {
                activateManager()
                let action = CommandLine.arguments.first(where: { ["--add-account", "--sessions", "--appearance"].contains($0) }) ?? "--manage"
                DistributedNotificationCenter.default().postNotificationName(requestName, object: store.root.path, userInfo: ["action": action], deliverImmediately: true)
            }
            NSApp.terminate(nil); return
        }
        ownsLock = true
        if isManager {
            NSApp.setActivationPolicy(lifecycleCheck ? .accessory : .regular)
            let mainMenu = NSMenu()
            let applicationItem = NSMenuItem(); mainMenu.addItem(applicationItem)
            let applicationMenu = NSMenu(); applicationItem.submenu = applicationMenu
            applicationMenu.addItem(withTitle: "关闭窗口", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
            applicationMenu.addItem(withTitle: "隐藏窗口", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
            applicationMenu.addItem(withTitle: "退出管理窗口", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
            let edit = NSMenuItem(title: "编辑", action: nil, keyEquivalent: ""); mainMenu.addItem(edit)
            let editMenu = NSMenu(title: "编辑"); edit.submenu = editMenu
            editMenu.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
            editMenu.addItem(withTitle: "复制", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
            editMenu.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
            editMenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
            NSApp.mainMenu = mainMenu
            let pidURL = store.root.appendingPathComponent("window.pid")
            try? Data(String(getpid()).utf8).write(to: pidURL, options: .atomic)
            manager = ManagerController(store: store, persistWindowFrame: !lifecycleCheck)
            if !lifecycleCheck { manager?.show() }
            commandObserver = DistributedNotificationCenter.default().addObserver(forName: requestName, object: store.root.path, queue: .main) { [weak self] note in
                self?.handleRequest(note.userInfo?["action"] as? String ?? "--manage")
            }
            let action = CommandLine.arguments.first(where: { ["--add-account", "--sessions", "--appearance"].contains($0) }) ?? "--manage"
            DispatchQueue.main.async { [weak self] in self?.handleRequest(action) }
            if let index = CommandLine.arguments.firstIndex(of: "--smoke-seconds"), index + 1 < CommandLine.arguments.count,
               let seconds = Double(CommandLine.arguments[index + 1]), seconds > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in self?.manager?.close() }
            }
        } else {
            NSApp.setActivationPolicy(.accessory)
            // Integration checks exercise the real scheduler without adding a fake menu icon.
            if !CommandLine.arguments.contains("--verify-auto-refresh") && !lifecycleCheck {
                let item = NSStatusBar.system.statusItem(withLength: 28)
                item.button?.image = MeterAppearance.symbol()
                item.button?.toolTip = "Agent Relay"
                let menu = NSMenu(); menu.delegate = self; menu.autoenablesItems = false
                item.menu = menu; self.item = item
                populate(menu)
            }
            if lifecycleCheck {
                let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
                    guard let self, FileManager.default.fileExists(atPath: self.store.root.appendingPathComponent("test-quit").path) else { return }
                    self.quit()
                }
                RunLoop.main.add(timer, forMode: .common)
                quitTimer = timer
            }
            let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in self?.refreshAutomatically() }
            timer.tolerance = 1
            RunLoop.main.add(timer, forMode: .common)
            refreshTimer = timer
            DispatchQueue.main.async { [weak self] in self?.refreshAutomatically() }
            if let index = CommandLine.arguments.firstIndex(of: "--smoke-menu-cycles"), index + 1 < CommandLine.arguments.count,
               let count = Int(CommandLine.arguments[index + 1]), (1...100).contains(count) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.smokeMenu(remaining: count) }
            }
        }
        observer = DistributedNotificationCenter.default().addObserver(forName: .init("dev.local.agent-meter.changed"), object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.manager?.reload()
            if let menu = self.item?.menu { self.populate(menu) }
        }
    }
    func applicationDidHide(_ notification: Notification) { manager?.hideAfterOperation() }
    func applicationDidBecomeActive(_ notification: Notification) {
        if !lifecycleCheck && isManager && NSApp.windows.allSatisfy({ !$0.isVisible }) { manager?.show() }
    }
    private func smokeMenu(remaining: Int) {
        guard remaining > 0, let menu = item?.menu else {
            try? Data("done".utf8).write(to: store.root.appendingPathComponent("menu-smoke-done"))
            return
        }
        let timer = Timer(timeInterval: 0.15, repeats: false) { _ in menu.cancelTrackingWithoutAnimation() }
        RunLoop.main.add(timer, forMode: .eventTracking)
        RunLoop.main.add(timer, forMode: .common)
        item?.button?.performClick(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in self?.smokeMenu(remaining: remaining - 1) }
    }
    func applicationWillTerminate(_ notification: Notification) {
        if let observer { DistributedNotificationCenter.default().removeObserver(observer) }
        if let commandObserver { DistributedNotificationCenter.default().removeObserver(commandObserver) }
        refreshTimer?.invalidate()
        quitTimer?.invalidate()
        worker?.terminate()
        if isManager && ownsLock { try? FileManager.default.removeItem(at: store.root.appendingPathComponent("window.pid")) }
        if instanceFD >= 0 { flock(instanceFD, LOCK_UN); Darwin.close(instanceFD) }
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if let manager, manager.isBusy { manager.close(); return .terminateCancel }
        // A rejected duplicate instance must never close the real manager.
        guard !isManager, ownsLock else { return .terminateNow }
        if quitting { return .terminateLater }
        quitting = true
        refreshTimer?.invalidate()
        lastMessage = "正在退出…"
        quitTimer?.invalidate()
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in self?.finishQuit() }
        quitTimer = timer
        RunLoop.main.add(timer, forMode: .common)
        return .terminateLater
    }
    private func finishQuit() {
        guard quitting else { return }
        if let app = runningManager() {
            // Normal AppKit termination also closes sheets and auxiliary windows.
            // The manager's delegate cancels and drains an active operation first.
            app.terminate()
            return
        }
        guard !launchingManager, worker == nil else { return }
        quitTimer?.invalidate(); quitTimer = nil
        NSApp.reply(toApplicationShouldTerminate: true)
    }
    func menuNeedsUpdate(_ menu: NSMenu) { populate(menu) }
    private func add(_ menu: NSMenu, _ title: String, action: Selector? = nil, value: String? = nil, enabled: Bool = true) {
        let entry = NSMenuItem(title: title, action: action, keyEquivalent: "")
        entry.target = self; entry.representedObject = value; entry.isEnabled = enabled && action != nil
        menu.addItem(entry)
    }
    private func populate(_ menu: NSMenu) {
        menu.removeAllItems()
        add(menu, "Agent Relay")
        if let lastMessage { add(menu, lastMessage) }
        if worker != nil { add(menu, "正在处理…") }
        let registry: Registry
        do { registry = try store.read() }
        catch { add(menu, "账号存储无法读取，请打开管理窗口。"); add(menu, "管理账号…", action: #selector(openManager)); return }
        updateStatusItem(registry)
        if let selected = registry.selected { add(menu, "CLI · \(selected.alias)") }
        if let session = registry.desktop, DesktopController.isVerified(session), let account = registry.accounts.first(where: { $0.id == session.accountID }) {
            add(menu, "桌面端 · \(account.alias) · 已验证")
        }
        menu.addItem(.separator())
        for account in registry.accounts.prefix(10) {
            let selected = account.id == registry.selectedID
            let entry = NSMenuItem(title: account.alias, action: nil, keyEquivalent: "")
            entry.state = selected ? .on : .off
            let actions = NSMenu(); actions.autoenablesItems = false
            add(actions, selected ? "CLI 当前账号" : "仅切换 CLI", action: #selector(switchCLI(_:)), value: account.id, enabled: worker == nil && !selected)
            add(actions, "切换桌面与 CLI", action: #selector(switchAccount(_:)), value: account.id, enabled: worker == nil)
            entry.submenu = actions; menu.addItem(entry)
            if let quota = account.quota {
                let windows = [quota.primary, quota.secondary].compactMap { $0 }.map { "\($0.label) \($0.remainingPercent)%" }.joined(separator: " · ")
                add(menu, "\(windows)\(quota.isStale ? " · 缓存" : "")")
            } else { add(menu, "尚未查询额度") }
            menu.items.last?.indentationLevel = 1
            if account.lastError != nil { add(menu, "查询失败"); menu.items.last?.indentationLevel = 1 }
        }
        if registry.accounts.isEmpty { add(menu, "添加账号后，在这里快速切换") }
        menu.addItem(.separator())
        add(menu, "管理账号…", action: #selector(openManager))
        add(menu, "本地会话…", action: #selector(openSessions))
        add(menu, "添加账号…", action: #selector(addAccount))
        add(menu, "外观…", action: #selector(openAppearance))
        add(menu, "菜单栏显示剩余额度", action: #selector(toggleMenuQuota))
        menu.items.last?.state = GlassPreferences.showMenuQuota ? .on : .off
        menu.items.last?.toolTip = "显示当前 CLI 账号的各周期剩余额度"
        let periodItem = NSMenuItem(title: "额度周期", action: nil, keyEquivalent: "")
        let periodMenu = NSMenu(); periodMenu.autoenablesItems = false
        for period in MenuQuotaPeriod.allCases {
            add(periodMenu, period.title, action: #selector(selectQuotaPeriod(_:)), value: period.rawValue)
            periodMenu.items.last?.state = period.rawValue == GlassPreferences.menuQuotaPeriod ? .on : .off
        }
        periodItem.submenu = periodMenu; menu.addItem(periodItem)
        add(menu, "刷新额度", action: #selector(refresh), enabled: worker == nil && !registry.accounts.isEmpty)
        menu.items.last?.toolTip = "自动刷新：所有账号约每 30 秒查询一次"
        menu.addItem(.separator())
        add(menu, "退出 Agent Relay", action: #selector(quit))
    }
    private func updateStatusItem(_ registry: Registry) {
        guard let item, let button = item.button else { return }
        item.length = GlassPreferences.showMenuQuota ? NSStatusItem.variableLength : 28
        button.imagePosition = GlassPreferences.showMenuQuota ? .imageLeading : .imageOnly
        button.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        let account = registry.selected
        let period = MenuQuotaPeriod(rawValue: GlassPreferences.menuQuotaPeriod) ?? .both
        let text = period.text(for: account?.quota)
        let stale = account?.quota?.isStale == true || account?.lastError != nil
        button.title = GlassPreferences.showMenuQuota ? " " + (text.isEmpty ? "额度 —" : text + (stale ? " *" : "")) : ""
        button.toolTip = "Agent Relay" + (account.map { " · CLI：\($0.alias)" } ?? " · 尚未选择账号") + (text.isEmpty ? "" : "\n剩余额度：" + text) + (stale ? "\n* 缓存数据，可在菜单中刷新额度" : "")
    }
    @objc private func selectQuotaPeriod(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, MenuQuotaPeriod(rawValue: raw) != nil else { return }
        GlassPreferences.menuQuotaPeriod = raw
        if let menu = item?.menu { populate(menu) }
    }
    @objc private func toggleMenuQuota() {
        GlassPreferences.showMenuQuota.toggle()
        if let menu = item?.menu { populate(menu) }
    }
    private func runningManager() -> NSRunningApplication? {
        let path = store.root.appendingPathComponent("window.pid")
        guard let data = try? String(contentsOf: path, encoding: .utf8), let pid = Int32(data),
              let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated,
              app.bundleIdentifier == Bundle.main.bundleIdentifier,
              app.bundleURL?.standardizedFileURL == Bundle.main.bundleURL.standardizedFileURL else { return nil }
        return app
    }
    private func activateManager() {
        guard let app = runningManager() else { return }
        NSApp.yieldActivation(to: app)
        app.activate(from: .current, options: [.activateAllWindows])
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if isManager { manager?.show() }
        else { launchManager(action: "--manage") }
        return true
    }
    private func handleRequest(_ action: String) {
        guard !lifecycleCheck else { return }
        switch action {
        case "--sessions": manager?.showSessions()
        case "--appearance": manager?.showAppearance()
        case "--add-account": manager?.show(); manager?.addAccount()
        default: manager?.show()
        }
    }
    @objc func openManager() { launchManager(action: "--manage") }
    @objc func addAccount() { launchManager(action: "--add-account") }
    @objc func openSessions() { launchManager(action: "--sessions") }
    @objc func openAppearance() { launchManager(action: "--appearance") }
    private func launchManager(action: String) {
        guard !quitting else { return }
        if let app = runningManager() {
            NSApp.yieldActivation(to: app)
            DistributedNotificationCenter.default().postNotificationName(requestName, object: store.root.path, userInfo: ["action": action], deliverImmediately: true)
            app.activate(from: .current, options: [.activateAllWindows])
            return
        }
        guard !launchingManager else { return }
        launchingManager = true
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.activates = true
        configuration.addsToRecentItems = false
        configuration.arguments = ["--manage"] + (action == "--manage" ? [] : [action])
        configuration.environment = ProcessInfo.processInfo.environment
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { [weak self] app, error in
            DispatchQueue.main.async {
                guard let self else { return }
                self.launchingManager = false
                if let app {
                    if self.quitting { app.terminate(); return }
                    NSApp.yieldActivation(to: app)
                    app.activate(from: .current, options: [.activateAllWindows])
                } else { self.lastMessage = "管理窗口启动失败：\(error?.localizedDescription ?? "未知错误")" }
            }
        }
    }
    @objc func switchCLI(_ sender: NSMenuItem) { if let id = sender.representedObject as? String { runWorker(["switch", id, "--cli-only"]) } }
    @objc func refresh() { runWorker(["quota"]) }
    @objc func switchAccount(_ sender: NSMenuItem) { if let id = sender.representedObject as? String { runWorker(["switch", id]) } }
    @objc func quit() { NSApp.terminate(nil) }
    private func refreshAutomatically() {
        guard !isManager, !quitting, worker == nil,
              let registry = try? store.read(),
              let id = refreshSchedule.next(in: registry) else { return }
        // Respect login/switch/refresh operations in the other process.
        guard (try? store.locked { true }) == true else { return }
        refreshSchedule.started(id)
        runWorker(["quota", id], automatic: true)
    }
    private func runWorker(_ arguments: [String], automatic: Bool = false) {
        guard !quitting, worker == nil else { return }
        let process = Process()
        process.executableURL = Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("agent-relay")
        process.arguments = arguments + ["--json"]
        let pipe = Pipe(); process.standardOutput = pipe; process.standardError = FileHandle.nullDevice; process.standardInput = FileHandle.nullDevice
        worker = process
        if !automatic { lastMessage = nil }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var data = Data()
            var errorText: String?
            do {
                try process.run(); try? pipe.fileHandleForWriting.close()
                while let chunk = try pipe.fileHandleForReading.read(upToCount: 16384), !chunk.isEmpty {
                    if data.count + chunk.count <= 1_048_576 { data.append(chunk) }
                }
                process.waitUntilExit()
                if process.terminationStatus != 0 {
                    let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                    errorText = object?["error"] as? String ?? "部分账号查询失败，请打开管理窗口查看。"
                }
            } catch {
                if process.isRunning { process.terminate(); process.waitUntilExit() }
                errorText = "操作未完成，请打开管理窗口重试。"
            }
            try? pipe.fileHandleForReading.close(); try? pipe.fileHandleForWriting.close()
            let result = errorText
            DispatchQueue.main.async {
                guard let self else { return }
                self.worker = nil
                if !automatic { self.lastMessage = result.map { String($0.prefix(65)) } }
                if let menu = self.item?.menu { self.populate(menu) }
                if automatic { self.refreshAutomatically() }
            }
        }
    }
    private func showFatal(_ text: String) {
        let alert = NSAlert(); alert.messageText = "Agent Relay 无法启动"; alert.informativeText = text; alert.runModal()
        NSApp.terminate(nil)
    }
}
