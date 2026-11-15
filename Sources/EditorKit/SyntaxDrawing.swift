import AppKit
import Highlight
import TextEngine

/// Syntax colours: tokens come from the highlighter per drawn line; glyphs are batched per
/// token kind, so a screen still takes one glyph draw call per colour.
extension EditorView {
	/// Colours of the theme matching the view's appearance, by token kind.
	func updateTokenColors() {
		let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
		let theme = dark ? Theme.dark : Theme.light
		tokenColors = TokenKind.allCases.map { kind in
			theme.rgba(kind).map { NSColor(srgbRed: $0.0, green: $0.1, blue: $0.2, alpha: $0.3) }
		}
	}

	/// UTF-16 unit ranges of the tokens (glyph indexes on the fast path).
	static func unitRuns(_ bytes: [UInt8], _ tokens: [Token]) -> [(Range<Int>, TokenKind)] {
		var runs: [(Range<Int>, TokenKind)] = []
		runs.reserveCapacity(tokens.count)
		var byte = 0, unit = 0
		func advance(to target: Int) {
			while byte < min(target, bytes.count) {
				let b = bytes[byte]
				if b & 0xC0 != 0x80 { unit += b >= 0xF0 ? 2 : 1 }
				byte += 1
			}
		}
		for t in tokens {
			advance(to: t.start)
			let start = unit
			advance(to: t.end)
			runs.append((start..<unit, t.kind))
		}
		return runs
	}

	func drawHighlighted(_ ctx: CGContext, lines: [Int], highlighter: SyntaxHighlighter, textColor: CGColor) {
		let kinds = TokenKind.allCases.count
		if colorGlyphs.count != kinds {
			colorGlyphs = Array(repeating: [], count: kinds)
			colorPositions = Array(repeating: [], count: kinds)
		}
		for k in 0..<kinds {
			colorGlyphs[k].removeAll(keepingCapacity: true)
			colorPositions[k].removeAll(keepingCapacity: true)
		}
		for line in lines {
			let l = layout(line)
			let baseline = y(ofLine: line) + ascent + 1
			let bytes = rope.bytes(in: rope.lineRange(line))
			let runs = Self.unitRuns(bytes, highlighter.tokens(line: line, bytes: bytes))
			if l.ctLine != nil {
				let colored = runs.compactMap { r, kind in tokenColors[Int(kind.rawValue)].map { (r, $0) } }
				guard let ct = l.colored(colored, attributes: textAttributes) else { continue }
				LineLayout.withBaseline(ctx, CGPoint(x: textInset, y: baseline)) { CTLineDraw(ct, ctx) }
				continue
			}
			var t = 0
			for g in 0..<l.glyphs.count {
				while t < runs.count && runs[t].0.upperBound <= g { t += 1 }
				let kind = t < runs.count && runs[t].0.lowerBound <= g ? Int(runs[t].1.rawValue) : 0
				colorGlyphs[kind].append(l.glyphs[g])
				let p = l.positions[g]
				colorPositions[kind].append(CGPoint(x: textInset + p.x, y: -baseline))
			}
		}
		for k in 0..<kinds where !colorGlyphs[k].isEmpty {
			ctx.setFillColor(tokenColors[k]?.cgColor ?? textColor)
			LineLayout.withBaseline(ctx, .zero) {
				CTFontDrawGlyphs(ctFont, colorGlyphs[k], colorPositions[k], colorGlyphs[k].count, ctx)
			}
		}
	}
}
