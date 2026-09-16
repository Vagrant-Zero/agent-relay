import AppKit

enum GlassPreferences {
    static let defaults = UserDefaults(suiteName: "dev.local.agent-meter.preview.appearance")!
    static let changed = Notification.Name("dev.local.agent-meter.appearance-changed")
    static var menuQuotaPeriod: String {
        get { defaults.string(forKey: "menuQuotaPeriod") ?? "both" }
        set { defaults.set(newValue, forKey: "menuQuotaPeriod") }
    }
    static var showMenuQuota: Bool {
        get { defaults.bool(forKey: "showMenuQuota") }
        set { defaults.set(newValue, forKey: "showMenuQuota") }
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
        wantsLayer = true; layer?.cornerRadius = 12; layer?.masksToBounds = true
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

final class AppearanceController {
    private let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 242), styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
    private let value = NSTextField(labelWithString: "")
    private let slider = NSSlider(value: GlassPreferences.transparency, minValue: 0, maxValue: 100, target: nil, action: nil)
    init() {
        window.title = "外观"; window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true; window.isOpaque = false; window.backgroundColor = .clear
        let surface = SurfaceView(); window.contentView = surface
        let title = NSTextField(labelWithString: "背景透明度")
        title.font = .systemFont(ofSize: 15, weight: .medium)
        value.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        let space = NSView(); space.setContentHuggingPriority(.init(1), for: .horizontal)
        let row = NSStackView(views: [title, space, value])
        slider.target = self; slider.action = #selector(change); slider.isContinuous = true
        slider.setAccessibilityLabel("背景透明度")
        let note = NSTextField(wrappingLabelWithString: "0% 为实色，100% 为全透明背景。标题栏和文字保持清晰；系统“减少透明度”开启时使用实色背景。")
        note.font = .systemFont(ofSize: 12); note.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [row, slider, note]); stack.orientation = .vertical; stack.spacing = 18; stack.alignment = .leading
        surface.contentHost.addSubview(stack); stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: surface.leadingAnchor, constant: 24), stack.trailingAnchor.constraint(equalTo: surface.trailingAnchor, constant: -24), stack.topAnchor.constraint(equalTo: surface.topAnchor, constant: 58)])
        for child in [row, slider, note] { child.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        updateValue()
    }
    func render(to url: URL, dark: Bool) throws { try MeterAppearance.render(window: window, to: url, dark: dark, size: NSSize(width: 380, height: 242)) }
    @objc private func change() { GlassPreferences.transparency = slider.doubleValue; updateValue() }
    private func updateValue() { value.stringValue = "\(Int(slider.doubleValue.rounded()))%" }
    func show() { slider.doubleValue = GlassPreferences.transparency; updateValue(); window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate() }
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
