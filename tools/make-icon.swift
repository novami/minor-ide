// Draws the app icon: dark royal blue squircle, "{" + "M" in a monospaced face and a caret.
// Usage: swift tools/make-icon.swift <out.iconset>; then iconutil -c icns <out.iconset>.
import AppKit

let out = CommandLine.arguments.dropFirst().first ?? "AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)

func draw(_ px: Int) -> Data? {
	let s = CGFloat(px)
	guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
	                                 hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
	      let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
	NSGraphicsContext.current = ctx
	let k = s / 1024 // design on the 1024 macOS icon grid: 824 x 824 body at 100
	let body = NSRect(x: 100 * k, y: 100 * k, width: 824 * k, height: 824 * k)
	let shape = NSBezierPath(roundedRect: body, xRadius: 185 * k, yRadius: 185 * k)
	NSGradient(starting: NSColor(srgbRed: 0.13, green: 0.22, blue: 0.62, alpha: 1),
	           ending: NSColor(srgbRed: 0.07, green: 0.11, blue: 0.38, alpha: 1))?.draw(in: shape, angle: -90)
	func text(_ string: String, size: CGFloat, color: NSColor, weight: NSFont.Weight, at point: NSPoint) {
		let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: size * k, weight: weight), .foregroundColor: color]
		NSAttributedString(string: string, attributes: attrs).draw(at: NSPoint(x: point.x * k, y: point.y * k))
	}
	text("{", size: 520, color: NSColor(srgbRed: 0.56, green: 0.71, blue: 1, alpha: 1), weight: .regular, at: NSPoint(x: 140, y: 175))
	text("M", size: 430, color: NSColor(srgbRed: 0.93, green: 0.95, blue: 1, alpha: 1), weight: .semibold, at: NSPoint(x: 395, y: 240))
	NSColor(srgbRed: 0.36, green: 0.79, blue: 0.65, alpha: 1).setFill()
	NSBezierPath(roundedRect: NSRect(x: 782 * k, y: 290 * k, width: 34 * k, height: 400 * k), xRadius: 12 * k, yRadius: 12 * k).fill()
	NSGraphicsContext.current = nil
	return rep.representation(using: .png, properties: [:])
}

for size in [16, 32, 128, 256, 512] {
	for scale in [1, 2] {
		let name = scale == 1 ? "icon_\(size)x\(size).png" : "icon_\(size)x\(size)@2x.png"
		try draw(size * scale)?.write(to: URL(fileURLWithPath: out + "/" + name))
	}
}
