// Draws the app icon: glossy blue gradient squircle, a rounded "M" and an amber underscore caret.
// Usage: swift Tools/make-icon.swift <out.iconset>; then iconutil -c icns <out.iconset>.
import AppKit

let out = CommandLine.arguments.dropFirst().first ?? "AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)

func roundedFont(_ size: CGFloat) -> NSFont {
	let f = NSFont.systemFont(ofSize: size, weight: .heavy)
	return f.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: size) } ?? f
}

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
	// Center the M by its glyph outline, not font metrics.
	let m = NSAttributedString(string: "M", attributes: [.font: roundedFont(520 * k), .foregroundColor: NSColor(srgbRed: 0.96, green: 0.97, blue: 1, alpha: 1)])
	let line = CTLineCreateWithAttributedString(m)
	let cg = ctx.cgContext
	cg.textPosition = .zero
	let b = CTLineGetImageBounds(line, cg)
	cg.textPosition = CGPoint(x: 450 * k - b.midX, y: 520 * k - b.midY)
	CTLineDraw(line, cg)
	NSColor(srgbRed: 1, green: 0.72, blue: 0.22, alpha: 1).setFill()
	NSBezierPath(roundedRect: NSRect(x: 700 * k, y: 330 * k, width: 120 * k, height: 34 * k), xRadius: 10 * k, yRadius: 10 * k).fill()
	NSGraphicsContext.current = nil
	return rep.representation(using: .png, properties: [:])
}

for size in [16, 32, 128, 256, 512] {
	for scale in [1, 2] {
		let name = scale == 1 ? "icon_\(size)x\(size).png" : "icon_\(size)x\(size)@2x.png"
		try draw(size * scale)?.write(to: URL(fileURLWithPath: out + "/" + name))
	}
}
