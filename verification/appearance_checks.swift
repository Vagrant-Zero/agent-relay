import AppKit

struct CheckFailure: Error { let message: String }
func require(_ condition: Bool, _ message: String = "Action failed") throws {
    if !condition { throw CheckFailure(message: message) }
}
func runChecks() throws {

let app = NSApplication.shared
let defaults = GlassPreferences.defaults
let previous = defaults.object(forKey: "transparency")
defer {
    if let previous { defaults.set(previous, forKey: "transparency") }
    else { defaults.removeObject(forKey: "transparency") }
    DistributedNotificationCenter.default().postNotificationName(GlassPreferences.changed, object: nil, userInfo: nil, deliverImmediately: true)
}
let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 242), styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
window.isOpaque = false; window.backgroundColor = .clear
let surface = SurfaceView(); window.contentView = surface
let label = NSTextField(labelWithString: "Readable foreground")
label.frame = NSRect(x: 20, y: 80, width: 220, height: 20)
surface.contentHost.addSubview(label)
func alpha(_ point: NSPoint) -> CGFloat {
    surface.layoutSubtreeIfNeeded()
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 380, pixelsHigh: 242, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    bitmap.size = surface.bounds.size
    surface.cacheDisplay(in: surface.bounds, to: bitmap)
    return bitmap.colorAt(x: Int(point.x), y: Int(point.y))!.alphaComponent
}
GlassPreferences.transparency = 0
let opaque = alpha(NSPoint(x: 350, y: 160))
GlassPreferences.transparency = 100
let clear = alpha(NSPoint(x: 350, y: 160))
let chrome = alpha(NSPoint(x: 190, y: 10))
try require(opaque > 0.99, "0% must have an opaque backdrop")
if !NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency {
    try require(clear < 0.01, "100% must remove the backdrop, got \(clear)")
    try require(chrome > 0.9, "Title bar must remain legible, got \(chrome)")
}
try require(label.alphaValue == 1 && surface.contentHost.alphaValue == 1, "Foreground must not fade")
let controller = SettingsController()
defer { withExtendedLifetime(controller) {} }
let settings = app.windows.first { $0.title == "设置" }!
func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
let slider = descendants(settings.contentView!).compactMap { $0 as? NSSlider }.first!
slider.doubleValue = 37
try require(app.sendAction(slider.action!, to: slider.target, from: slider))
try require(GlassPreferences.transparency == 37, "Slider must persist its value")
try require(settings.styleMask.contains(.fullSizeContentView), "Glass must extend under title bar")
print("Appearance checks passed: opaque=\(opaque), transparent=\(clear), title=\(chrome); slider action and foreground opacity verified")

}
do { try runChecks() } catch { fputs("Appearance check failed: \(error)\n", stderr); exit(1) }
