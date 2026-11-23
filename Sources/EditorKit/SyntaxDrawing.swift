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
		highContrast = increasedContrast
		var background: (Double, Double, Double)?
		if highContrast {
			effectiveAppearance.performAsCurrentDrawingAppearance {
				if let bg = NSColor.textBackgroundColor.usingColorSpace(.sRGB) {
					background = (Double(bg.redComponent), Double(bg.greenComponent), Double(bg.blueComponent))
				}
			}
		}
		tokenColors = TokenKind.allCases.map { kind in
			let rgba = background.map { theme.rgba(kind, contrast: 7, against: $0) } ?? theme.rgba(kind)
			return rgba.map { NSColor(srgbRed: $0.0, green: $0.1, blue: $0.2, alpha: $0.3) }
		}
	}

	/// Increase Contrast (System Settings › Accessibility › Display): token colours reach 7:1
	/// against the background and highlights get stronger.
	var increasedContrast: Bool {
		if NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast { return true }
		let match = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua])
		return match == .accessibilityHighContrastAqua || match == .accessibilityHighContrastDarkAqua
	}

	func observeContrastSetting() {
		contrastObserver = NSWorkspace.shared.notificationCenter.addObserver(
			forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
			MainActor.assumeIsolated {
				guard let self else { return }
				self.updateTokenColors()
				self.needsDisplay = true
				self.sticky?.needsDisplay = true
			}
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

	/// Text of the rows, coloured by tokens when there is a highlighter. Each row draws the
	/// glyphs of its units shifted left by the x of its first unit; fallback lines (CTLine)
	/// draw whole, clipped to the row.
	func drawText(_ ctx: CGContext, rows: [(line: Int, segment: Int)], highlighter: SyntaxHighlighter?, textColor: CGColor,
	              xRange: ClosedRange<CGFloat> = -.infinity...(.infinity)) {
		// Glyphs outside the drawn columns are skipped (a horizontal scroll redraws a strip).
		let minX = xRange.lowerBound - 4 * lineHeight, maxX = xRange.upperBound
		let kinds = TokenKind.allCases.count
		if colorGlyphs.count != kinds {
			colorGlyphs = Array(repeating: [], count: kinds)
			colorPositions = Array(repeating: [], count: kinds)
		}
		for k in 0..<kinds {
			colorGlyphs[k].removeAll(keepingCapacity: true)
			colorPositions[k].removeAll(keepingCapacity: true)
		}
		var line = -1
		var l: LineLayout?
		var runs: [(Range<Int>, TokenKind)] = []
		var b: [Int] = []
		for row in rows {
			if row.line != line {
				line = row.line
				l = layout(line)
				b = breaks(ofLine: line)
				if let highlighter {
					let bytes = rope.bytes(in: rope.lineRange(line))
					runs = Self.unitRuns(bytes, document.colorTokens(line: line, bytes: bytes, highlighter: highlighter))
				}
			}
			guard let l else { continue }
			let top = y(ofLine: line) + CGFloat(row.segment) * lineHeight
			let baseline = top + ascent + 1
			let units = b.isEmpty ? 0..<l.unitCount : segmentUnits(line: line, segment: row.segment, b)
			let shift = l.x(atUnit: units.lowerBound)
			if l.ctLine != nil {
				let colored = runs.compactMap { r, kind in tokenColors[Int(kind.rawValue)].map { (r, $0) } }
				let ct = highlighter == nil ? l.ctLine : l.colored(colored, attributes: textAttributes)
				guard let ct else { continue }
				ctx.saveGState()
				if !b.isEmpty {
					ctx.clip(to: CGRect(x: textInset, y: top, width: l.x(atUnit: units.upperBound) - shift + 1, height: lineHeight))
				}
				LineLayout.withBaseline(ctx, CGPoint(x: textInset - shift, y: baseline)) { CTLineDraw(ct, ctx) }
				ctx.restoreGState()
				continue
			}
			var t = 0
			for g in units where g < l.glyphs.count {
				let x = textInset + l.positions[g].x - shift
				if x < minX { continue }
				if x > maxX { break }
				while t < runs.count && runs[t].0.upperBound <= g { t += 1 }
				let kind = t < runs.count && runs[t].0.lowerBound <= g ? Int(runs[t].1.rawValue) : 0
				colorGlyphs[kind].append(l.glyphs[g])
				colorPositions[kind].append(CGPoint(x: x, y: -baseline))
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
