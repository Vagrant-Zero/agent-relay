import AppKit
import AgentMeterCore

final class ActionButton: NSButton {
    var invoke: (() -> Void)?
    convenience init(_ title: String, action: @escaping () -> Void) {
        self.init(title: title, target: nil, action: nil)
        bezelStyle = .rounded; target = self; self.action = #selector(clicked)
        self.invoke = action
    }
    @objc private func clicked() { invoke?() }
}
final class FlippedView: NSView { override var isFlipped: Bool { true } }
final class ClosureMenuItem: NSMenuItem {
    private var invoke: (() -> Void)?
    init(_ title: String, action: @escaping () -> Void) {
        super.init(title: title, action: nil, keyEquivalent: "")
        invoke = action; target = self; self.action = #selector(clicked)
    }
    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    @objc private func clicked() { invoke?() }
}
final class ManagerController: NSObject, NSWindowDelegate {
    private let store: Store
    private let window: NSWindow
    private let rows = NSStackView()
    private let subtitle = NSTextField(labelWithString: "账号与额度")
    private let stateLabel = NSTextField(labelWithString: "")
    private let feedback = NSTextField(wrappingLabelWithString: "")
    private let spinner = NSProgressIndicator()
    private var cancellation: Cancellation?
    private var shouldClose = false
    private var controls: [NSControl] = []
    private var sessionsController: SessionsController?
    private var appearanceController: AppearanceController?
    func showSessions() {
        if sessionsController == nil { sessionsController = SessionsController(store: store) }
        sessionsController?.show()
    }
    func showAppearance() {
        if appearanceController == nil { appearanceController = AppearanceController() }
        appearanceController?.show()
    }
    private(set) var isBusy = false

    init(store: Store) {
        self.store = store
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 740, height: 470),
                          styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        super.init()
        window.title = "Agent Meter"
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 680, height: 380)
        window.delegate = self
        window.setFrameAutosaveName("AgentMeterPreview.Manager")
        build()
        reload()
    }
    func show() {
        shouldClose = false
        window.center(); window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        if let index = CommandLine.arguments.firstIndex(of: "--snapshot"), index + 1 < CommandLine.arguments.count {
            let path = CommandLine.arguments[index + 1]
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard let view = self?.window.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
                view.cacheDisplay(in: view.bounds, to: bitmap)
                try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            }
        }
    }
    /// Render only this app's view tree, without displaying or capturing a desktop window.
    func render(to url: URL, dark: Bool, size: NSSize) throws {
        try MeterAppearance.render(window: window, to: url, dark: dark, size: size)
    }
    private func label(_ text: String, size: CGFloat = 13, weight: NSFont.Weight = .regular, color: NSColor = .labelColor) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: size, weight: weight); label.textColor = color
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }
    private func stack(_ views: [NSView], vertical: Bool = false, spacing: CGFloat = 8) -> NSStackView {
        let stack = NSStackView(views: views); stack.orientation = vertical ? .vertical : .horizontal
        stack.alignment = vertical ? .leading : .centerY; stack.spacing = spacing
        return stack
    }
    private func pin(_ view: NSView, to parent: NSView, inset: CGFloat = 0) {
        view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: parent.leadingAnchor, constant: inset),
            view.trailingAnchor.constraint(equalTo: parent.trailingAnchor, constant: -inset),
            view.topAnchor.constraint(equalTo: parent.topAnchor, constant: inset),
            view.bottomAnchor.constraint(equalTo: parent.bottomAnchor, constant: -inset)
        ])
    }
    private func spacer() -> NSView {
        let view = NSView(); view.setContentHuggingPriority(.init(1), for: .horizontal)
        return view
    }
    private func build() {
        let background = SurfaceView()
        window.isOpaque = false; window.backgroundColor = .clear
        window.contentView = background
        let content = NSView(); background.contentHost.addSubview(content)
        content.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: background.topAnchor, constant: 48),
            content.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -18),
            content.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 28),
            content.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -28)
        ])
        let mark = NSImageView(image: MeterAppearance.symbol())
        mark.contentTintColor = .labelColor
        mark.widthAnchor.constraint(equalToConstant: 24).isActive = true
        let heading = label("Agent Meter", size: 18, weight: .medium)
        let sessions = ActionButton("本地会话") { [weak self] in self?.showSessions() }
        let appearance = ActionButton("") { [weak self] in self?.showAppearance() }
        appearance.isBordered = false
        appearance.image = NSImage(systemSymbolName: "slider.horizontal.3", accessibilityDescription: "外观")
        appearance.toolTip = "外观与透明度"
        let add = ActionButton("添加账号") { [weak self] in self?.addAccount() }
        sessions.isBordered = false
        add.isBordered = false
        add.image = NSImage(systemSymbolName: "plus", accessibilityDescription: nil)
        add.imagePosition = .imageLeading
        add.keyEquivalent = "n"; add.keyEquivalentModifierMask = [.command]
        let top = stack([mark, heading, spacer(), sessions, add, appearance], spacing: 12)
        let refresh = ActionButton("") { [weak self] in self?.refresh() }
        refresh.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "刷新额度")
        refresh.isBordered = false; refresh.toolTip = "刷新额度"
        refresh.setAccessibilityLabel("刷新额度")
        controls = [add, refresh]
        subtitle.font = .systemFont(ofSize: 13, weight: .medium)
        subtitle.textColor = .secondaryLabelColor
        stateLabel.font = .systemFont(ofSize: 11); stateLabel.textColor = .secondaryLabelColor
        let strip = stack([subtitle, spacer(), stateLabel, refresh], spacing: 10)
        let line = MeterAppearance.divider()
        let scroll = NSScrollView(); scroll.drawsBackground = false; scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay; scroll.horizontalScrollElasticity = .none
        let document = FlippedView(); scroll.documentView = document
        rows.orientation = .vertical; rows.alignment = .leading; rows.spacing = 0
        document.addSubview(rows)
        document.translatesAutoresizingMaskIntoConstraints = false
        document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor).isActive = true
        pin(rows, to: document)
        spinner.style = .spinning; spinner.controlSize = .small; spinner.isDisplayedWhenStopped = false
        feedback.font = .systemFont(ofSize: 11); feedback.textColor = .secondaryLabelColor
        let cancel = ActionButton("取消") { [weak self] in self?.cancellation?.cancel() }
        cancel.identifier = .init("cancelOperation")
        let progress = stack([spinner, feedback, spacer(), cancel], spacing: 8)
        [top, strip, line, scroll, progress].forEach { content.addSubview($0); $0.translatesAutoresizingMaskIntoConstraints = false }
        NSLayoutConstraint.activate([
            top.leadingAnchor.constraint(equalTo: content.leadingAnchor), top.trailingAnchor.constraint(equalTo: content.trailingAnchor), top.topAnchor.constraint(equalTo: content.topAnchor),
            strip.topAnchor.constraint(equalTo: top.bottomAnchor, constant: 28), strip.leadingAnchor.constraint(equalTo: content.leadingAnchor), strip.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            line.topAnchor.constraint(equalTo: strip.bottomAnchor, constant: 12), line.leadingAnchor.constraint(equalTo: content.leadingAnchor), line.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: line.bottomAnchor), scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            progress.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 10), progress.leadingAnchor.constraint(equalTo: content.leadingAnchor), progress.trailingAnchor.constraint(equalTo: content.trailingAnchor), progress.heightAnchor.constraint(greaterThanOrEqualToConstant: 22),
            progress.bottomAnchor.constraint(equalTo: content.bottomAnchor)
        ])
        cancel.isHidden = true
    }
    func reload() {
        let registry: Registry
        do { registry = try store.read() }
        catch { feedback.stringValue = "账号文件无法读取：\(error.localizedDescription)"; return }
        rows.arrangedSubviews.forEach { rows.removeArrangedSubview($0); $0.removeFromSuperview() }
        stateLabel.stringValue = ""
        if let session = registry.desktop, DesktopController.isVerified(session),
           let account = registry.accounts.first(where: { $0.id == session.accountID }) {
            stateLabel.stringValue += "    桌面 · \(account.alias) ✓"
        }
        subtitle.stringValue = registry.accounts.isEmpty ? "Codex" : "Codex · 剩余额度"
        if registry.accounts.isEmpty {
            let icon = NSImageView(image: MeterAppearance.symbol())
            icon.contentTintColor = .tertiaryLabelColor
            icon.widthAnchor.constraint(equalToConstant: 30).isActive = true
            icon.heightAnchor.constraint(equalToConstant: 30).isActive = true
            let emptyAdd = ActionButton("添加账号") { [weak self] in self?.addAccount() }
            emptyAdd.isEnabled = !isBusy
            let empty = stack([icon, label("添加你的第一个账号", size: 17, weight: .medium), label("登录后，即可查看额度并切换账号。", size: 12, color: .secondaryLabelColor), emptyAdd], vertical: true, spacing: 12)
            empty.alignment = .centerX
            let holder = NSView(); holder.addSubview(empty); empty.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([empty.centerXAnchor.constraint(equalTo: holder.centerXAnchor), empty.centerYAnchor.constraint(equalTo: holder.centerYAnchor), holder.heightAnchor.constraint(equalToConstant: 260)])
            rows.addArrangedSubview(holder); holder.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true
        } else {
            for account in registry.accounts {
                let card = accountCard(account, registry: registry)
                rows.addArrangedSubview(card)
                card.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true
            }
        }
        controls.forEach { $0.isEnabled = !isBusy }
        findCancel(in: window.contentView)?.isHidden = !isBusy
    }
    private func accountCard(_ account: Account, registry: Registry) -> NSView {
        let card = NSView()
        let selected = registry.selectedID == account.id
        let desktop = registry.desktop.map { $0.accountID == account.id && DesktopController.isVerified($0) } ?? false
        let name = stack([label(account.alias, size: 14, weight: .medium), label(selected ? "CLI" : "", size: 10, color: .secondaryLabelColor)], spacing: 6)
        let identity = stack([name, label(account.email, size: 11, color: .secondaryLabelColor),
                              label("\(account.plan.capitalized) · 重置卡 \(account.quota?.resetCards.map(String.init) ?? "—")\(account.quota?.isStale == true ? " · 缓存" : "")", size: 10, color: .secondaryLabelColor)], vertical: true, spacing: 5)
        identity.widthAnchor.constraint(equalToConstant: 174).isActive = true
        let metrics = stack([quotaView(account.quota?.primary, fallback: "额度")], spacing: 22)
        if let second = account.quota?.secondary { metrics.addArrangedSubview(quotaView(second, fallback: "额度")) }
        metrics.distribution = .fillEqually
        let menu = NSPopUpButton(frame: .zero, pullsDown: true)
        menu.controlSize = .small; menu.isBordered = false; menu.isEnabled = !isBusy
        menu.addItem(withTitle: "切换")
        func action(_ title: String, enabled: Bool = true, _ block: @escaping () -> Void) {
            let item = ClosureMenuItem(title, action: block); item.isEnabled = enabled
            menu.menu?.addItem(item)
        }
        menu.menu?.autoenablesItems = false
        action(selected ? "CLI 当前账号" : "仅切换 CLI", enabled: !selected) { [weak self] in
            self?.perform("正在切换 CLI…") { service in try service.selectCLI(account.id); return "CLI 已切换。" }
        }
        action(desktop ? "桌面当前账号" : "切换桌面与 CLI", enabled: !(desktop && selected)) { [weak self] in
            self?.perform("正在切换桌面账号…") { service in
                try DesktopController(store: service.store, cancellation: service.cancellation).switchAccount(account.id)
                return "桌面账号已验证，CLI 已同步。"
            }
        }
        menu.menu?.addItem(.separator())
        action("移除账号…") { [weak self] in self?.remove(account) }
        let row = stack([identity, metrics, menu], spacing: 20)
        metrics.setContentHuggingPriority(.defaultLow, for: .horizontal)
        var views: [NSView] = [row]
        if let error = account.lastError {
            let warning = NSTextField(wrappingLabelWithString: error)
            warning.font = .systemFont(ofSize: 11); warning.textColor = .systemOrange
            views.append(warning)
        }
        card.toolTip = "\(Format.updated(account.quota?.fetchedAt))\(desktop ? " · 桌面使用中" : "")"
        let body = stack(views, vertical: true, spacing: 8)
        card.addSubview(body); body.translatesAutoresizingMaskIntoConstraints = false
        let line = MeterAppearance.divider(); card.addSubview(line); line.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            body.topAnchor.constraint(equalTo: card.topAnchor, constant: 20), body.leadingAnchor.constraint(equalTo: card.leadingAnchor), body.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            line.topAnchor.constraint(equalTo: body.bottomAnchor, constant: 20), line.leadingAnchor.constraint(equalTo: card.leadingAnchor), line.trailingAnchor.constraint(equalTo: card.trailingAnchor), line.bottomAnchor.constraint(equalTo: card.bottomAnchor),
            row.widthAnchor.constraint(equalTo: body.widthAnchor)
        ])
        return card
    }
    private func quotaView(_ quota: QuotaWindow?, fallback: String) -> NSView {
        let title = label(quota?.label ?? fallback, size: 11, color: .secondaryLabelColor)
        let percent = label(quota.map { "\($0.remainingPercent)%" } ?? "—", size: 13, weight: .medium)
        percent.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        let row = stack([title, spacer(), percent])
        let bar = QuotaBar(remaining: quota?.remainingPercent)
        let reset = label(quota.map { "\(Format.reset($0.resetsAt)) 重置" } ?? "尚未查询", size: 10, color: .secondaryLabelColor)
        let block = stack([row, bar, reset], vertical: true, spacing: 7)
        row.widthAnchor.constraint(equalTo: block.widthAnchor).isActive = true
        bar.widthAnchor.constraint(equalTo: block.widthAnchor).isActive = true
        return block
    }
    private func findCancel(in view: NSView?) -> NSView? {
        guard let view else { return nil }
        if view.identifier?.rawValue == "cancelOperation" { return view }
        for child in view.subviews { if let result = findCancel(in: child) { return result } }
        return nil
    }
    private func perform(_ title: String, work: @escaping (AccountService) throws -> String) {
        guard !isBusy else { return }
        isBusy = true
        let cancellation = Cancellation(); self.cancellation = cancellation
        feedback.stringValue = title; feedback.textColor = .secondaryLabelColor
        spinner.startAnimation(nil); reload()
        let store = self.store
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result: Result<String, Error>
            do { result = .success(try work(AccountService(store: store, cancellation: cancellation))) }
            catch { result = .failure(error) }
            DispatchQueue.main.async {
                guard let self else { return }
                self.isBusy = false; self.cancellation = nil; self.spinner.stopAnimation(nil)
                switch result {
                case .success(let message): self.feedback.stringValue = message; self.feedback.textColor = .secondaryLabelColor
                case .failure(let error): self.feedback.stringValue = error.localizedDescription; self.feedback.textColor = .systemOrange
                }
                self.reload()
                if self.shouldClose { NSApp.terminate(nil) }
            }
        }
    }
    func addAccount() {
        guard !isBusy else { return }
        let alert = NSAlert(); alert.messageText = "添加 Codex 账号"
        alert.informativeText = "输入一个便于区分的名称，接着在系统浏览器的官方页面登录。"
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 28))
        input.placeholderString = "例如：个人、工作"; alert.accessoryView = input
        alert.addButton(withTitle: "打开官方登录"); alert.addButton(withTitle: "取消")
        alert.window.initialFirstResponder = input
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            let alias = input.stringValue
            self.perform("等待官方网页登录完成…（5 分钟内有效）") { service in
                let account = try service.login(alias: alias) { url in
                    var opened = false
                    DispatchQueue.main.sync { opened = NSWorkspace.shared.open(url) }
                    if !opened { throw MeterError.message("无法打开系统浏览器，请检查默认浏览器设置。") }
                }
                return "已添加 \(account.alias)。"
            }
        }
    }
    private func refresh() {
        perform("正在获取最新额度…") { service in
            let accounts = try service.refresh()
            let failures = accounts.filter { $0.lastError != nil }.count
            return failures == 0 ? "已更新全部账号的额度。" : "\(failures) 个账号查询失败，已保留上次额度。"
        }
    }
    private func remove(_ account: Account) {
        let alert = NSAlert(); alert.messageText = "移除「\(account.alias)」？"
        alert.informativeText = "只从列表移除。原有凭据、对话历史和已运行的 CLI 会话会保留。"
        alert.addButton(withTitle: "移除"); alert.addButton(withTitle: "取消")
        alert.beginSheetModal(for: window) { [weak self] response in
            if response == .alertFirstButtonReturn {
                self?.perform("正在移除账号…") { service in try service.remove(account.id); return "账号已从列表移除。" }
            }
        }
    }
    func close() {
        if isBusy { shouldClose = true; cancellation?.cancel(); window.orderOut(nil) }
        else { window.close() }
    }
    func hideAfterOperation() {
        shouldClose = true
        window.orderOut(nil)
        if !isBusy { NSApp.terminate(nil) }
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if isBusy { close(); return false }
        return true
    }
    func windowWillClose(_ notification: Notification) { NSApp.terminate(nil) }
}
