import AppKit

enum GlassPreferences {
    static let defaults = UserDefaults(suiteName: "dev.local.agent-meter.preview.appearance")!
    static let changed = Notification.Name("dev.local.agent-meter.appearance-changed")
    static func notify() {
        DistributedNotificationCenter.default().postNotificationName(changed, object: nil, userInfo: nil, deliverImmediately: true)
        NotificationCenter.default.post(name: changed, object: nil)
    }
    static var automaticUpdates: Bool {
        get { defaults.object(forKey: "automaticUpdates") == nil ? true : defaults.bool(forKey: "automaticUpdates") }
        set { defaults.set(newValue, forKey: "automaticUpdates"); notify() }
    }
    static var menuQuotaPeriod: String {
        get { defaults.string(forKey: "menuQuotaPeriod") ?? "both" }
        set { defaults.set(newValue, forKey: "menuQuotaPeriod"); notify() }
    }
    static var showMenuQuota: Bool {
        get { defaults.bool(forKey: "showMenuQuota") }
        set { defaults.set(newValue, forKey: "showMenuQuota"); notify() }
    }
    static var transparency: Double {
        get { defaults.object(forKey: "transparency") == nil ? 65 : min(100, max(0, defaults.double(forKey: "transparency"))) }
        set {
            defaults.set(newValue, forKey: "transparency")
            DistributedNotificationCenter.default().postNotificationName(changed, object: nil, userInfo: nil, deliverImmediately: true)
            NotificationCenter.default.post(name: changed, object: nil)
        }
    }
}

private final class GlassContentView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let opacity = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency ? 1 : 1 - GlassPreferences.transparency / 100
        MeterAppearance.background.withAlphaComponent(opacity).setFill()
        bounds.fill(using: .copy)
        // Full-size content covers the title bar too. Keep traffic lights and title legible.
        MeterAppearance.background.withAlphaComponent(0.94).setFill()
        NSRect(x: 0, y: max(0, bounds.height - 32), width: bounds.width, height: min(32, bounds.height)).fill()
    }
}

final class SurfaceView: NSView {
    let contentHost: NSView = GlassContentView()
    private let effect: NSView
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    override init(frame: NSRect) {
        let glass = NSGlassEffectView()
        glass.style = .clear; glass.cornerRadius = 12
        glass.contentView = NSView()
        effect = glass
        super.init(frame: frame)
        // NSGlassEffectView owns its backing layers; the foreground stays AppKit-drawn.
        // Layer-backing the parent would allocate backing stores for every descendant.
        addSubview(effect)
        effect.frame = bounds; effect.autoresizingMask = [.width, .height]
        // Foreground is a sibling: fading the glass must never fade labels or controls.
        addSubview(contentHost)
        contentHost.frame = bounds; contentHost.autoresizingMask = [.width, .height]
        for (center, name) in [(NotificationCenter.default, GlassPreferences.changed),
                               (DistributedNotificationCenter.default() as NotificationCenter, GlassPreferences.changed),
                               (NSWorkspace.shared.notificationCenter, NSWorkspace.accessibilityDisplayOptionsDidChangeNotification)] {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.update() }
            observers.append((center, token))
        }
        update()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    deinit { for (center, token) in observers { center.removeObserver(token) } }
    private func update() {
        let reduced = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        effect.alphaValue = reduced ? 0 : 1 - GlassPreferences.transparency / 100
        effect.isHidden = reduced || GlassPreferences.transparency >= 100
        contentHost.needsDisplay = true
        needsDisplay = true
    }
}

private final class SettingsDocumentView: NSView { override var isFlipped: Bool { true } }

final class SettingsController: NSObject, NSWindowDelegate {
    var onClose: (() -> Void)?
    private var window: NSWindow?
    private let value = NSTextField(labelWithString: "")
    private let slider = NSSlider(value: GlassPreferences.transparency, minValue: 0, maxValue: 100, target: nil, action: nil)
    private let showQuota = NSButton(checkboxWithTitle: "菜单栏显示剩余额度", target: nil, action: nil)
    private let period = NSPopUpButton()
    private let automatic = NSButton(checkboxWithTitle: "自动检查更新（每天）", target: nil, action: nil)
    private let checkUpdates: () -> Void
    init(contentHost: NSView? = nil, checkUpdates: @escaping () -> Void = {}) {
        self.checkUpdates = checkUpdates
        super.init()
        let host: NSView
        if let contentHost { host = contentHost }
        else {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 430, height: 456), styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
            self.window = window
            window.delegate = self
            window.title = "设置"; window.isReleasedWhenClosed = false
            window.titlebarAppearsTransparent = true; window.isOpaque = false; window.backgroundColor = .clear
            let surface = SurfaceView(); window.contentView = surface; host = surface.contentHost
        }
        func text(_ title: String, size: CGFloat = 12, secondary: Bool = false) -> NSTextField {
            let label = NSTextField(wrappingLabelWithString: title)
            label.font = .systemFont(ofSize: size, weight: size == 14 ? .medium : .regular)
            label.textColor = secondary ? .secondaryLabelColor : .labelColor
            return label
        }
        func row(_ views: [NSView]) -> NSStackView {
            let stack = NSStackView(views: views); stack.spacing = 10; return stack
        }
        let space = NSView(); space.setContentHuggingPriority(.init(1), for: .horizontal)
        let transparency = row([text("背景透明度"), space, value])
        value.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        slider.target = self; slider.action = #selector(change); slider.isContinuous = true
        slider.setAccessibilityLabel("背景透明度")
        showQuota.target = self; showQuota.action = #selector(changeQuota)
        period.addItems(withTitles: ["5 小时", "每周", "同时显示"])
        period.target = self; period.action = #selector(changePeriod)
        automatic.target = self; automatic.action = #selector(changeAutomatic)
        let update = NSButton(title: "检查更新…", target: self, action: #selector(check))
        update.bezelStyle = .rounded
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "开发版"
        let versionSpace = NSView(); versionSpace.setContentHuggingPriority(.init(1), for: .horizontal)
        let views: [NSView] = [text("外观", size: 14), transparency, slider,
            text("透明度只影响背景，标题栏和文字保持清晰。", secondary: true),
            MeterAppearance.divider(), text("菜单栏", size: 14), showQuota,
            row([text("显示周期"), period]), MeterAppearance.divider(), text("软件更新", size: 14),
            row([text("当前版本  \(version)", secondary: true), versionSpace, update]), automatic,
            text("发现新版本后提示，下载和安装由你确认。", secondary: true)]
        let stack = NSStackView(views: views); stack.orientation = .vertical; stack.spacing = 12; stack.alignment = .leading
        let scroll = NSScrollView(); scroll.drawsBackground = false
        scroll.hasVerticalScroller = true; scroll.scrollerStyle = .overlay
        let document = SettingsDocumentView(); scroll.documentView = document
        host.addSubview(scroll); scroll.translatesAutoresizingMaskIntoConstraints = false
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack); stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: host.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: host.topAnchor, constant: contentHost == nil ? 52 : 76), scroll.bottomAnchor.constraint(equalTo: host.bottomAnchor, constant: -16),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 24), stack.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: document.topAnchor), stack.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -8)
        ])
        for child in views { child.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        synchronize()
    }
    func windowWillClose(_ notification: Notification) { onClose?() }
    private func synchronize() {
        slider.doubleValue = GlassPreferences.transparency
        value.stringValue = "\(Int(slider.doubleValue.rounded()))%"
        showQuota.state = GlassPreferences.showMenuQuota ? .on : .off
        period.selectItem(at: ["fiveHours", "weekly", "both"].firstIndex(of: GlassPreferences.menuQuotaPeriod) ?? 2)
        period.isEnabled = GlassPreferences.showMenuQuota
        automatic.state = GlassPreferences.automaticUpdates ? .on : .off
    }
    func render(to url: URL, dark: Bool) throws { guard let window else { return }; try MeterAppearance.render(window: window, to: url, dark: dark, size: NSSize(width: 430, height: 456)) }
    @objc private func change() { GlassPreferences.transparency = slider.doubleValue; value.stringValue = "\(Int(slider.doubleValue.rounded()))%" }
    @objc private func changeQuota() { GlassPreferences.showMenuQuota = showQuota.state == .on; synchronize() }
    @objc private func changePeriod() { GlassPreferences.menuQuotaPeriod = ["fiveHours", "weekly", "both"][period.indexOfSelectedItem] }
    @objc private func changeAutomatic() { GlassPreferences.automaticUpdates = automatic.state == .on }
    @objc private func check() { checkUpdates() }
    func show() { synchronize(); window?.center(); window?.makeKeyAndOrderFront(nil); NSApp.activate() }
}

enum MeterAppearance {
    static let background = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.12, green: 0.12, blue: 0.115, alpha: 1)
            : NSColor(srgbRed: 0.985, green: 0.98, blue: 0.965, alpha: 1)
    }
    static func render(window: NSWindow, to url: URL, dark: Bool, size: NSSize) throws {
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.setContentSize(size)
        guard let view = window.contentView else { return }
        view.layoutSubtreeIfNeeded()
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return }
        bitmap.size = size
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { return }
        try png.write(to: url)
    }
    static func symbol() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            // Three closed loops form a compact ring with an open center.
            // Draw as vectors so the thin strokes remain crisp at menu-bar scale.
            NSColor.black.setStroke()
            for index in 0..<3 {
                let loop = NSBezierPath(ovalIn: NSRect(x: -6.25, y: -3.7, width: 12.5, height: 7.4))
                let rotation = AffineTransform(rotationByDegrees: CGFloat(index * 60 + 30))
                loop.transform(using: rotation)
                loop.transform(using: AffineTransform(translationByX: 9, byY: 9))
                loop.lineWidth = 1.25
                loop.stroke()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Agent Relay"
        return image
    }

    static func divider() -> NSBox {
        let view = NSBox(); view.boxType = .separator
        return view
    }
}

final class QuotaBar: NSView {
    let remaining: Int?
    init(remaining: Int?) {
        self.remaining = remaining
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityLabel(remaining.map { "剩余额度 \($0)%" } ?? "额度未知")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 4) }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.quaternaryLabelColor.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 2, yRadius: 2).fill()
        guard let remaining, remaining > 0 else { return }
        (remaining <= 10 ? NSColor.systemOrange : NSColor.labelColor.withAlphaComponent(0.65)).setFill()
        let filled = NSRect(x: 0, y: 0, width: bounds.width * Double(remaining) / 100, height: bounds.height)
        NSBezierPath(roundedRect: filled, xRadius: 2, yRadius: 2).fill()
    }
}
