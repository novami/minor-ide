import Highlight
import TextEngine

/// Semantic colouring from the language server, laid over the lexer's tokens when drawing.
/// Tokens follow edits until the next set arrives; tokens an edit touches are dropped.
extension TextDocument {
	/// Replaces the semantic tokens: one sorted array per line (offsets in bytes from the line
	/// start); empty clears them. A set for another line count is ignored.
	public func setSemanticTokens(_ lines: [[Token]]) {
		let new = lines.allSatisfy(\.isEmpty) ? [] : lines
		guard new.isEmpty || new.count == rope.lineCount else { return }
		if new.isEmpty && semanticLines.isEmpty { return }
		semanticLines = new
		for view in views {
			view.needsDisplay = true
			view.sticky?.needsDisplay = true
		}
	}

	public var hasSemanticTokens: Bool { !semanticLines.isEmpty }

	public func semanticTokens(line: Int) -> [Token] { line < semanticLines.count ? semanticLines[line] : [] }

	/// The line's lexer tokens with the semantic tokens over them.
	func colorTokens(line: Int, bytes: [UInt8], highlighter: SyntaxHighlighter) -> [Token] {
		let base = highlighter.tokens(line: line, bytes: bytes)
		guard line < semanticLines.count else { return base }
		return Token.overlay(base, semanticLines[line])
	}

	/// Moves the tokens of the lines `firstLine...oldLastLine` of `old` through `changes`.
	func moveSemanticTokens(_ changes: ChangeSet, old: Rope, firstLine: Int, oldLastLine: Int, newLastLine: Int) {
		guard !semanticLines.isEmpty else { return }
		guard semanticLines.count == old.lineCount, oldLastLine < semanticLines.count else {
			semanticLines = []
			return
		}
		var moved = Array(repeating: [Token](), count: newLastLine - firstLine + 1)
		let list = changes.changes
		var first = 0 // first change not ending before the token (tokens come in text order)
		for line in firstLine...oldLastLine {
			let base = old.offset(ofLine: line)
			for t in semanticLines[line] {
				let a = base + t.start, b = base + t.end
				while first < list.count && list[first].range.upperBound < a { first += 1 }
				// Dropped when an edit replaces part of it or inserts inside it.
				var touched = false
				var k = first
				while k < list.count && list[k].range.lowerBound < b {
					let r = list[k].range
					if r.isEmpty ? a < r.lowerBound : a < r.upperBound {
						touched = true
						break
					}
					k += 1
				}
				if touched { continue }
				let start = changes.map(a, bias: .after)
				let newLine = rope.line(containing: start)
				let index = newLine - firstLine
				guard index >= 0, index < moved.count else { continue }
				moved[index].append(Token(start - rope.offset(ofLine: newLine), t.length, t.kind))
			}
		}
		semanticLines.replaceSubrange(firstLine...oldLastLine, with: moved)
	}
}
