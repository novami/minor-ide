import AppKit
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
	private let expandedIndex: [Int] // fallback: string index in the tab-expanded text per unit boundary
	/// Fallback: the tab-expanded text, to typeset again with token colours.
	private var expandedText: String?
	let width: CGFloat

	var unitCount: Int { ctLine == nil ? unitX.count - 1 : expandedIndex.count - 1 }

	/// x offset before the UTF-16 unit at `index` (tabs expanded).
	func x(atUnit index: Int) -> CGFloat {
		let i = min(max(index, 0), unitCount)
		guard let ctLine else { return unitX[i] }
		return CTLineGetOffsetForStringIndex(ctLine, expandedIndex[i], nil)
	}

	/// Tabs advance to the next tab stop, not by a fixed width.
	@inline(__always) static func nextTabStop(_ x: CGFloat, space: CGFloat, tabWidth: Int) -> CGFloat {
		let stop = space * CGFloat(tabWidth)
		return (floor(x / stop + 0.001) + 1) * stop
	}

	init(bytes: [UInt8], font: CTFont, ascii: AsciiGlyphs, tabWidth: Int, attributes: [NSAttributedString.Key: Any]) {
		if let fast = LineLayout.asciiPath(bytes, ascii, tabWidth) {
			(unitX, glyphs, positions, ctLine, expandedIndex) = (fast.unitX, fast.glyphs, fast.positions, nil, [])
			width = fast.unitX.last ?? 0
			return
		}
		var text = String(decoding: bytes, as: UTF8.self)
		if text.hasSuffix("\r") { text.removeLast() }
		let units = Array(text.utf16)

		if let fast = LineLayout.fastPath(units, font, tabWidth) {
			(unitX, glyphs, positions, ctLine, expandedIndex) = (fast.unitX, fast.glyphs, fast.positions, nil, [])
			width = fast.unitX.last ?? 0
			return
		}
		// Fallback: expand tabs so the typesetter sees the same columns as the fast path.
		// Expand tabs to the next tab stop by column (UTF-16 units approximate columns here).
		var expanded: [UInt16] = []
		var map = [0]
		for u in units {
			if u == 0x09 {
				let spaces = tabWidth - expanded.count % tabWidth
				expanded.append(contentsOf: repeatElement(0x20, count: spaces))
			} else {
				expanded.append(u)
			}
			map.append(expanded.count)
		}
		let line = CTLineCreateWithAttributedString(NSAttributedString(
			string: String(utf16CodeUnits: expanded, count: expanded.count), attributes: attributes))
		(unitX, glyphs, positions, ctLine, expandedIndex) = ([], [], [], line, map)
		expandedText = String(utf16CodeUnits: expanded, count: expanded.count)
		width = CTLineGetTypographicBounds(line, nil, nil, nil)
	}

	/// Pure ASCII lines (most code): table lookups only, no String and no Core Text calls.
	private static func asciiPath(_ bytes: [UInt8], _ ascii: AsciiGlyphs, _ tabWidth: Int) -> (unitX: [CGFloat], glyphs: [CGGlyph], positions: [CGPoint])? {
		var n = bytes.count
		if n > 0 && bytes[n - 1] == 0x0D { n -= 1 }
		var glyphs = [CGGlyph](repeating: 0, count: n)
		var positions = [CGPoint](repeating: .zero, count: n)
		var unitX = [CGFloat](repeating: 0, count: n + 1)
		var x: CGFloat = 0
		for i in 0..<n {
			let b = Int(bytes[i])
			guard b < 0x80, ascii.glyphs[b] != 0 || b == 0x09 else { return nil }
			if b == 0x09 {
				glyphs[i] = ascii.glyphs[0x20]
				positions[i] = CGPoint(x: x, y: 0)
				x = nextTabStop(x, space: ascii.advances[0x20], tabWidth: tabWidth)
			} else {
				glyphs[i] = ascii.glyphs[b]
				positions[i] = CGPoint(x: x, y: 0)
				x += ascii.advances[b]
			}
			unitX[i + 1] = x
		}
		return (unitX, glyphs, positions)
	}

	private static func fastPath(_ units: [UInt16], _ font: CTFont, _ tabWidth: Int) -> (unitX: [CGFloat], glyphs: [CGGlyph], positions: [CGPoint])? {
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
			x = units[i] == 0x09 ? nextTabStop(x, space: advances[i].width, tabWidth: tabWidth) : x + advances[i].width // tab maps to the space glyph
			unitX[i + 1] = x
		}
		return (unitX, glyphs, positions)
	}

	/// Draws with the baseline at `origin` in a flipped (y-down) view.
	/// Fallback line typeset again with colours for UTF-16 unit ranges (syntax colouring).
	func colored(_ runs: [(Range<Int>, NSColor)], attributes: [NSAttributedString.Key: Any]) -> CTLine? {
		guard let expandedText else { return nil }
		let s = NSMutableAttributedString(string: expandedText, attributes: attributes)
		for (r, color) in runs {
			let a = expandedIndex[min(r.lowerBound, unitCount)], b = expandedIndex[min(r.upperBound, unitCount)]
			if a < b { s.addAttribute(.foregroundColor, value: color, range: NSRange(location: a, length: b - a)) }
		}
		return CTLineCreateWithAttributedString(s)
	}

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

/// Glyphs and advances of the ASCII range for one font, looked up once.
struct AsciiGlyphs {
	var glyphs = [CGGlyph](repeating: 0, count: 128)
	var advances = [CGFloat](repeating: 0, count: 128)

	init(font: CTFont) {
		var chars = (0..<128).map { UInt16($0) }
		_ = CTFontGetGlyphsForCharacters(font, &chars, &glyphs, 128) // control characters stay 0
		var sizes = [CGSize](repeating: .zero, count: 128)
		CTFontGetAdvancesForGlyphs(font, .horizontal, glyphs, &sizes, 128)
		advances = sizes.map(\.width)
	}
}
