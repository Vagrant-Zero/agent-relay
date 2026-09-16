import AppKit
import AgentMeterCore

final class SessionsController: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate, NSWindowDelegate {
    private let store: Store
    private let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 520), styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
    private let table = NSTableView()
    private let accounts = NSPopUpButton()
    private let search = NSSearchField()
    private let status = NSTextField(wrappingLabelWithString: "")
    private var sessions: [LocalSession] = []
    private var visible: [LocalSession] = []
    private var registry = Registry()
    private var extraRoots: [String] = []
    private let scanQueue = DispatchQueue(label: "dev.local.agent-meter.sessions", qos: .userInitiated)
    private var generation = 0
    private var retry: DispatchWorkItem?
    private var scanWarnings: [String] = []
    private var isLoading = false

    init(store: Store) {
        self.store = store
        super.init()
        window.title = "本地会话"
        window.titlebarAppearsTransparent = true
        window.isOpaque = false; window.backgroundColor = .clear
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.minSize = NSSize(width: 680, height: 400)
        let content = NSStackView(); content.orientation = .vertical; content.alignment = .leading; content.spacing = 16
        content.edgeInsets = NSEdgeInsets(top: 56, left: 28, bottom: 20, right: 28)
        let surface = SurfaceView(); window.contentView = surface; surface.contentHost.addSubview(content)
        content.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: surface.topAnchor), content.bottomAnchor.constraint(equalTo: surface.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: surface.leadingAnchor), content.trailingAnchor.constraint(equalTo: surface.trailingAnchor)
        ])
        let heading = NSTextField(labelWithString: "本地会话")
        heading.font = .systemFont(ofSize: 18, weight: .medium)
        let hint = NSTextField(wrappingLabelWithString: "选择一段对话，换个账号继续。")
        hint.font = .systemFont(ofSize: 12)
        hint.textColor = .secondaryLabelColor
        search.placeholderString = "搜索标题、项目路径或会话 ID"; search.delegate = self
        let refresh = ActionButton("刷新") { [weak self] in self?.reload() }
        let add = ActionButton("添加目录…") { [weak self] in self?.addSource() }
        add.isBordered = false; refresh.isBordered = false
        let toolbar = NSStackView(views: [search, refresh, add]); toolbar.spacing = 8
        for (name, width) in [("会话", 360.0), ("项目", 330.0)] {
            let column = NSTableColumn(identifier: .init(name)); column.title = name; column.width = width
            table.addTableColumn(column)
        }
        table.delegate = self; table.dataSource = self; table.rowHeight = 44
        table.usesAlternatingRowBackgroundColors = false
        table.backgroundColor = .clear
        table.style = .plain; table.intercellSpacing = NSSize(width: 12, height: 1)
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.documentView = table
        scroll.drawsBackground = false
        let restore = ActionButton("恢复会话") { [weak self] in self?.restore() }
        restore.toolTip = "在终端中恢复完整会话"
        let space = NSView(); space.setContentHuggingPriority(.init(1), for: .horizontal)
        let bottom = NSStackView(views: [NSTextField(labelWithString: "使用账号"), accounts, space, restore]); bottom.spacing = 10
        status.font = .systemFont(ofSize: 12); status.textColor = .secondaryLabelColor
        [heading, hint, toolbar, scroll, bottom, status].forEach { content.addArrangedSubview($0) }
        for view in [hint, toolbar, scroll, bottom, status] { view.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -56).isActive = true }
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 180).isActive = true
        accounts.setContentHuggingPriority(.defaultLow, for: .horizontal)
    }

    func show() { window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(); reload() }
    func render(to url: URL, dark: Bool, size: NSSize) throws {
        reload(designRoots: [store.root])
        try MeterAppearance.render(window: window, to: url, dark: dark, size: size)
    }
    /// Exercise the same first-load path as the window, without account clicks.
    func verifyInitialLoad() throws -> [String] {
        reload()
        let deadline = Date().addingTimeInterval(20)
        while isLoading && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
        guard !isLoading else { throw MeterError.message("会话首次加载超时。") }
        guard scanWarnings.isEmpty else { throw MeterError.message(scanWarnings.joined(separator: "\n")) }
        return visible.map { $0.id }
    }
    private func reload(designRoots: [URL]? = nil, attempt: Int = 0) {
        generation += 1
        let request = generation
        retry?.cancel(); retry = nil
        do {
            registry = try store.read()
            let previous = accounts.selectedItem?.representedObject as? String
            accounts.removeAllItems()
            for account in registry.accounts {
                accounts.addItem(withTitle: "\(account.alias) · \(account.email)")
                accounts.lastItem?.representedObject = account.profilePath
            }
            var known = Set(registry.accounts.map { $0.profilePath })
            let roots = try designRoots ?? LocalSessions.roots(store: store, additional: extraRoots)
            for root in roots where FileManager.default.fileExists(atPath: root.appendingPathComponent("auth.json").path) {
                if known.insert(root.path).inserted {
                    accounts.addItem(withTitle: "本地账号 · \(root.lastPathComponent)")
                    accounts.lastItem?.representedObject = root.path
                }
            }
            if let item = accounts.itemArray.first(where: { ($0.representedObject as? String) == (previous ?? registry.selected?.profilePath) }) { accounts.select(item) }
            if designRoots != nil {
                apply(LocalSessions.scan(roots: roots, retaining: sessions))
                return
            }
            isLoading = true
            updateStatus()
            let previousSessions = sessions
            scanQueue.async { [weak self] in
                let result = LocalSessions.scan(roots: roots, retaining: previousSessions)
                DispatchQueue.main.async {
                    guard let self, self.generation == request else { return }
                    self.apply(result)
                    if !result.warnings.isEmpty && attempt < 3 && self.window.isVisible {
                        let work = DispatchWorkItem { [weak self] in
                            guard let self, self.generation == request, self.window.isVisible else { return }
                            self.reload(attempt: attempt + 1)
                        }
                        self.retry = work
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
                    }
                }
            }
        } catch {
            isLoading = false
            status.stringValue = error.localizedDescription
        }
    }
    private func apply(_ result: LocalSessions.Scan) {
        isLoading = false
        sessions = result.sessions
        scanWarnings = result.warnings
        filter()
    }
    private func updateStatus() {
        let count = search.stringValue.isEmpty ? "\(sessions.count) 个本地会话" : "显示 \(visible.count) / \(sessions.count) 个会话"
        status.stringValue = count + (isLoading ? " · 正在刷新…" : scanWarnings.isEmpty ? "" : " · 部分目录暂时不可读，已保留会话，可稍后刷新。")
        status.toolTip = scanWarnings.isEmpty ? nil : scanWarnings.joined(separator: "\n")
    }
    func windowWillClose(_ notification: Notification) {
        generation += 1; retry?.cancel(); retry = nil; isLoading = false
    }
    private func filter() {
        let selectedID = visible.indices.contains(table.selectedRow) ? visible[table.selectedRow].id : nil
        let needle = search.stringValue
        visible = sessions.filter { needle.isEmpty || "\($0.title) \($0.cwd) \($0.id)".localizedCaseInsensitiveContains(needle) }
        table.reloadData()
        if let selectedID, let row = visible.firstIndex(where: { $0.id == selectedID }) { table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
        updateStatus()
    }
    func controlTextDidChange(_ obj: Notification) { filter() }
    func numberOfRows(in tableView: NSTableView) -> Int { visible.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let session = visible[row]
        let isTitle = tableColumn?.identifier.rawValue == "会话"
        let field = NSTextField(labelWithString: isTitle ? session.title.components(separatedBy: .newlines).joined(separator: " ") : (session.cwd as NSString).abbreviatingWithTildeInPath)
        field.font = .systemFont(ofSize: 12, weight: isTitle ? .medium : .regular)
        field.textColor = isTitle ? .labelColor : .secondaryLabelColor
        field.lineBreakMode = .byTruncatingTail; field.toolTip = "\(session.id)\n\(session.cwd)"
        let cell = NSView(); cell.addSubview(field); field.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: cell.leadingAnchor), field.trailingAnchor.constraint(equalTo: cell.trailingAnchor),
            field.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])
        return cell
    }
    private func addSource() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.prompt = "添加"; panel.message = "选择包含 state_5.sqlite 的 Codex 数据目录。"
        panel.beginSheetModal(for: window) { [weak self] result in
            guard result == .OK, let path = panel.url?.path else { return }
            self?.extraRoots.append(path); self?.reload()
        }
    }
    private func restore() {
        guard visible.indices.contains(table.selectedRow) else { status.stringValue = "请先选择一个会话。"; return }
        guard let account = accounts.selectedItem?.representedObject as? String else { status.stringValue = "请先添加一个登录账号。"; return }
        let session = visible[table.selectedRow]
        do {
            _ = try session.resumeArguments()
            let cli = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/agent-relay").path
            func quote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
            let folder = store.root.appendingPathComponent("terminal-launchers")
            try Store.privateDirectory(folder)
            let file = folder.appendingPathComponent(UUID().uuidString + ".command")
            let command = [cli, "resume", "--profile", account, "--source", session.databaseHome, session.id].map(quote).joined(separator: " ")
            let script = "#!/bin/zsh\nexport AGENT_METER_HOME=\(quote(store.root.path))\ncd -- \(quote(session.cwd)) || exit 1\nexec \(command)\n"
            try Data(script.utf8).write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
            NSWorkspace.shared.open([file], withApplicationAt: URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"), configuration: NSWorkspace.OpenConfiguration()) { [weak self] _, error in
                DispatchQueue.main.async { self?.status.stringValue = error.map { "无法打开终端：\($0.localizedDescription)" } ?? "已打开终端，正在恢复所选会话。" }
            }
        } catch { status.stringValue = error.localizedDescription }
    }
}
