// Draws the app icon: glossy blue gradient squircle, "{" + "M" in a monospaced face and a caret.
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
	NSGraphicsContext.saveGraphicsState()
	let shadow = NSShadow()
	shadow.shadowColor = NSColor(white: 0, alpha: 0.35)
	shadow.shadowOffset = NSSize(width: 0, height: -10 * k)
	shadow.shadowBlurRadius = 24 * k
	shadow.set()
	NSColor.black.setFill()
	shape.fill()
	NSGraphicsContext.restoreGraphicsState()
	NSGradient(colors: [NSColor(srgbRed: 0.30, green: 0.62, blue: 1, alpha: 1),
	                    NSColor(srgbRed: 0.12, green: 0.38, blue: 0.90, alpha: 1),
	                    NSColor(srgbRed: 0.04, green: 0.16, blue: 0.52, alpha: 1)])?.draw(in: shape, angle: -90)
	// Gloss: a soft white sheen over the upper half, curving down like light on a lens.
	NSGraphicsContext.saveGraphicsState()
	shape.addClip()
	let gloss = NSBezierPath(ovalIn: NSRect(x: -60 * k, y: 520 * k, width: 1144 * k, height: 700 * k))
	NSGradient(starting: NSColor(white: 1, alpha: 0.30), ending: NSColor(white: 1, alpha: 0.0))?.draw(in: gloss, angle: -90)
	NSGraphicsContext.restoreGraphicsState()
	// Hairline rim: light at the top edge, fading out toward the bottom.
	NSGraphicsContext.saveGraphicsState()
	shape.addClip()
	let rim = NSBezierPath(roundedRect: body.insetBy(dx: 3 * k, dy: 3 * k), xRadius: 182 * k, yRadius: 182 * k)
	rim.lineWidth = 6 * k
	NSColor(white: 1, alpha: 0.25).setStroke()
	rim.stroke()
	NSGraphicsContext.restoreGraphicsState()
	let glyphShadow = NSShadow()
	glyphShadow.shadowColor = NSColor(srgbRed: 0, green: 0.05, blue: 0.25, alpha: 0.45)
	glyphShadow.shadowOffset = NSSize(width: 0, height: -6 * k)
	glyphShadow.shadowBlurRadius = 14 * k
	glyphShadow.set()
	func text(_ string: String, size: CGFloat, color: NSColor, weight: NSFont.Weight, at point: NSPoint) {
		let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: size * k, weight: weight), .foregroundColor: color]
		NSAttributedString(string: string, attributes: attrs).draw(at: NSPoint(x: point.x * k, y: point.y * k))
	}
	text("{", size: 520, color: NSColor(srgbRed: 0.72, green: 0.84, blue: 1, alpha: 1), weight: .regular, at: NSPoint(x: 125, y: 175))
	text("M", size: 430, color: NSColor(srgbRed: 0.93, green: 0.95, blue: 1, alpha: 1), weight: .semibold, at: NSPoint(x: 430, y: 240))
	NSColor(srgbRed: 0.36, green: 0.79, blue: 0.65, alpha: 1).setFill()
	NSBezierPath(roundedRect: NSRect(x: 800 * k, y: 290 * k, width: 34 * k, height: 400 * k), xRadius: 12 * k, yRadius: 12 * k).fill()
	NSGraphicsContext.current = nil
	return rep.representation(using: .png, properties: [:])
}

for size in [16, 32, 128, 256, 512] {
	for scale in [1, 2] {
		let name = scale == 1 ? "icon_\(size)x\(size).png" : "icon_\(size)x\(size)@2x.png"
		try draw(size * scale)?.write(to: URL(fileURLWithPath: out + "/" + name))
	}
}
