import CoreText
import Foundation

/// Layout of one text line. Lines whose characters all map 1:1 to glyphs of the editor
/// font take a fast path (glyph array + positions drawn with one CTFontDrawGlyphs call);
/// anything else (emoji, combining marks, font fallback) is typeset with a CTLine.
struct LineLayout {
	/// Fast path: x offset of each UTF-16 unit boundary, `units + 1` entries, tabs expanded.
	private let unitX: [CGFloat]
	let glyphs: [CGGlyph]
	let positions: [CGPoint] // baseline-relative, y = 0
	/// Fallback path: the typeset line and the units, so offsets are computed only when asked.
	let ctLine: CTLine?
	private let units: [UInt16]
	let width: CGFloat

	var unitCount: Int { ctLine == nil ? unitX.count - 1 : units.count }

	/// x offset before the UTF-16 unit at `index` (tabs expanded).
	func x(atUnit index: Int) -> CGFloat {
		let i = min(max(index, 0), unitCount)
		guard let ctLine else { return unitX[i] }
		let expanded = units[0..<i].reduce(0) { $0 + ($1 == 0x09 ? LineLayout.tabWidth : 1) }
		return CTLineGetOffsetForStringIndex(ctLine, expanded, nil)
	}

	static let tabWidth = 4

	init(bytes: some Collection<UInt8>, font: CTFont, attributes: [NSAttributedString.Key: Any]) {
		var text = String(decoding: bytes, as: UTF8.self)
		if text.hasSuffix("\r") { text.removeLast() }
		let units = Array(text.utf16)

		if let fast = LineLayout.fastPath(units, font) {
			(unitX, glyphs, positions, ctLine, self.units) = (fast.unitX, fast.glyphs, fast.positions, nil, [])
			width = fast.unitX.last ?? 0
			return
		}
		// Fallback: expand tabs so the typesetter sees the same columns as the fast path.
		let expanded = text.replacingOccurrences(of: "\t", with: String(repeating: " ", count: LineLayout.tabWidth))
		let line = CTLineCreateWithAttributedString(NSAttributedString(string: expanded, attributes: attributes))
		(unitX, glyphs, positions, ctLine, self.units) = ([], [], [], line, units)
		width = CTLineGetTypographicBounds(line, nil, nil, nil)
	}

	private static func fastPath(_ units: [UInt16], _ font: CTFont) -> (unitX: [CGFloat], glyphs: [CGGlyph], positions: [CGPoint])? {
		for u in units where u >= 0x0300 {
			// Combining marks, surrogate pairs (emoji) and anything beyond Latin/Greek/Cyrillic
			// can need shaping or fallback fonts.
			if (0x0300...0x036F).contains(u) || u >= 0x0590 { return nil }
		}
		var glyphs = [CGGlyph](repeating: 0, count: units.count)
		var mapped = units.map { $0 == 0x09 ? 0x20 : $0 } // tab draws as a (wide) space
		guard units.isEmpty || CTFontGetGlyphsForCharacters(font, &mapped, &glyphs, units.count),
		      !glyphs.contains(0)
		else { return nil }
		var advances = [CGSize](repeating: .zero, count: units.count)
		CTFontGetAdvancesForGlyphs(font, .horizontal, glyphs, &advances, units.count)

		var unitX = [CGFloat](repeating: 0, count: units.count + 1)
		var positions = [CGPoint](repeating: .zero, count: units.count)
		var x: CGFloat = 0
		for i in 0..<units.count {
			positions[i] = CGPoint(x: x, y: 0)
			x += units[i] == 0x09 ? advances[i].width * CGFloat(tabWidth) : advances[i].width
			unitX[i + 1] = x
		}
		return (unitX, glyphs, positions)
	}

	/// Draws with the baseline at `origin` in a flipped (y-down) view.
	func draw(in ctx: CGContext, font: CTFont, at origin: CGPoint) {
		guard ctLine != nil || !glyphs.isEmpty else { return }
		LineLayout.withBaseline(ctx, origin) {
			if let ctLine {
				CTLineDraw(ctLine, ctx)
			} else {
				CTFontDrawGlyphs(font, glyphs, positions, glyphs.count, ctx)
			}
		}
	}

	/// Flips the CTM (not the text matrix: a flipped text matrix misplaces accents and
	/// mark attachments) and resets the text position, which both draw calls add to.
	static func withBaseline(_ ctx: CGContext, _ origin: CGPoint, _ body: () -> Void) {
		ctx.saveGState()
		ctx.translateBy(x: origin.x, y: origin.y)
		ctx.scaleBy(x: 1, y: -1)
		ctx.textMatrix = .identity
		ctx.textPosition = .zero
		body()
		ctx.restoreGState()
	}

	/// UTF-16 unit index nearest to x (rounding to the closer boundary).
	func unitIndex(atX x: CGFloat) -> Int {
		var lo = 0
		var hi = unitCount
		while lo < hi {
			let mid = (lo + hi) / 2
			if self.x(atUnit: mid) < x { lo = mid + 1 } else { hi = mid }
		}
		if lo > 0 && x - self.x(atUnit: lo - 1) < self.x(atUnit: lo) - x { return lo - 1 }
		return lo
	}
}
