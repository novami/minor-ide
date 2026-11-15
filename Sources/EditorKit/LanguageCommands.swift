import AppKit
import Highlight
import TextEngine

/// Commands that need the language: comments, bracket and quote pairs, smart indentation.
/// They look at the lexer's tokens, so nothing pairs or indents inside strings and comments.
extension EditorView {
	/// Kind of the token around `offset` (strictly inside it), nil in plain code.
	func tokenKind(around offset: Int) -> TokenKind? {
		guard let highlighter else { return nil }
		let line = rope.line(containing: offset)
		let column = offset - rope.offset(ofLine: line)
		return highlighter.tokens(line: line, in: rope).first { $0.start < column && column < $0.end }?.kind
	}

	private func inStringOrComment(_ offset: Int) -> Bool {
		guard let kind = tokenKind(around: offset) else { return false }
		return kind == .string || kind == .comment || kind == .escape
	}

	private func byte(before offset: Int) -> UInt8 { offset > 0 ? rope.byte(at: offset - 1) : 0 }
	private func byte(at offset: Int) -> UInt8 { offset < rope.byteCount ? rope.byte(at: offset) : 0 }

	/// One indentation unit of the document.
	var indentUnit: String {
		format.indentStyle == .tab ? "\t" : String(repeating: " ", count: max(1, format.indentSize))
	}

	// MARK: Comments

	/// ⌘/: comments the selected lines out, or back in when all of them are comments.
	@objc public func toggleComment(_ sender: Any?) {
		guard let language else { return NSSound.beep() }
		var edits: [(Range<Int>, String)] = []
		for block in selectedLineBlocks() {
			let state = highlighter?.state(atLine: block.lowerBound, in: rope) ?? .start
			switch language.comment(at: state) {
			case .line(let prefix):
				edits += lineCommentEdits(block, prefix: Array(prefix.utf8))
			case .block(let open, let close):
				edits += blockCommentEdits(block, open: Array(open.utf8), close: Array(close.utf8))
			}
		}
		guard !edits.isEmpty else { return }
		apply(ChangeSet(edits), kind: .other) { selections.mapped(through: $0) }
	}

	/// Leading whitespace length and the line bytes; nil for a blank line.
	private func content(of line: Int) -> (indent: Int, bytes: [UInt8])? {
		let bytes = rope.bytes(in: rope.lineRange(line))
		guard let first = bytes.firstIndex(where: { !Bytes.isWhitespace($0) }) else { return nil }
		return (first, bytes)
	}

	private func lineCommentEdits(_ block: ClosedRange<Int>, prefix: [UInt8]) -> [(Range<Int>, String)] {
		let lines = block.compactMap { line in content(of: line).map { (line, $0.indent, $0.bytes) } }
		guard !lines.isEmpty else { return [] }
		let commented = lines.allSatisfy { _, indent, bytes in bytes[indent...].starts(with: prefix) }
		if commented {
			return lines.map { line, indent, bytes in
				let start = rope.offset(ofLine: line) + indent
				let space = bytes.count > indent + prefix.count && bytes[indent + prefix.count] == 0x20 ? 1 : 0
				return (start..<(start + prefix.count + space), "")
			}
		}
		// Insert at the smallest indentation, so the comment markers line up.
		let column = lines.map(\.1).min()!
		let text = String(decoding: prefix, as: UTF8.self) + " "
		return lines.map { line, _, _ in
			let at = rope.offset(ofLine: line) + column
			return (at..<at, text)
		}
	}

	private func blockCommentEdits(_ block: ClosedRange<Int>, open: [UInt8], close: [UInt8]) -> [(Range<Int>, String)] {
		guard let first = (block.lowerBound...block.upperBound).first(where: { content(of: $0) != nil }),
		      let last = (block.lowerBound...block.upperBound).reversed().first(where: { content(of: $0) != nil }),
		      let head = content(of: first), let tail = content(of: last) else { return [] }
		let start = rope.offset(ofLine: first) + head.indent
		var endIndex = tail.bytes.count
		while endIndex > 0 && Bytes.isWhitespace(tail.bytes[endIndex - 1]) { endIndex -= 1 }
		let end = rope.offset(ofLine: last) + endIndex
		let text = rope.bytes(in: start..<end)
		if text.starts(with: open) && text.count >= open.count + close.count && Array(text.suffix(close.count)) == close {
			let openSpace = text.count > open.count && text[open.count] == 0x20 ? 1 : 0
			let closeSpace = text.count > open.count + close.count && text[text.count - close.count - 1] == 0x20 ? 1 : 0
			return [(start..<(start + open.count + openSpace), ""), ((end - close.count - closeSpace)..<end, "")]
		}
		return [(start..<start, String(decoding: open, as: UTF8.self) + " "), (end..<end, " " + String(decoding: close, as: UTF8.self))]
	}

	// MARK: Pairs

	private func closing(for open: UInt8) -> UInt8? {
		guard let language else { return nil }
		if let pair = language.brackets.first(where: { $0.open == open }) { return pair.close }
		return language.quotes.contains(open) ? open : nil
	}

	private func isClosingBracket(_ b: UInt8) -> Bool {
		language?.brackets.contains { $0.close == b } ?? false
	}

	/// Typing a bracket or quote: wraps a selection, inserts the pair, types over the closing
	/// character, or outdents a closing bracket on an otherwise empty line. False when the
	/// character is not special here (the caller inserts it).
	func typePairCharacter(_ c: UInt8) -> Bool {
		guard let language else { return false }
		let isQuote = language.quotes.contains(c)
		let close = closing(for: c)
		guard close != nil || isClosingBracket(c) else { return false }
		enum Plan { case insert, wrap, pair, over, outdent(Range<Int>, String) }
		let plans: [Plan] = selections.all.map { s in
			if !s.isEmpty { return close != nil ? .wrap : .insert }
			let p = s.head, next = byte(at: p), prev = byte(before: p)
			if (isClosingBracket(c) || isQuote) && next == c && prev != 0x5C { return .over }
			if let _ = close, !inStringOrComment(p) {
				let nextOK = next == 0 || next == 0x0A || Bytes.isWhitespace(next) || isClosingBracket(next) || next == 0x2C || next == 0x3B
				let prevOK = !isQuote || !(Bytes.isIdentifier(prev) || prev == c || prev == 0x5C)
				if nextOK && prevOK { return .pair }
			}
			if isClosingBracket(c) {
				let lineStart = rope.offset(ofLine: rope.line(containing: p))
				let before = rope.bytes(in: lineStart..<p)
				if !before.isEmpty && before.allSatisfy(Bytes.isWhitespace) {
					var indent = String(decoding: before, as: UTF8.self)
					if indent.hasSuffix("\t") { indent.removeLast() } else { indent = String(indent.dropLast(min(indent.count, max(1, format.indentSize)))) }
					return .outdent(lineStart..<p, indent)
				}
			}
			return .insert
		}
		let text = String(UnicodeScalar(c))
		let closeText = close.map { String(UnicodeScalar($0)) } ?? ""
		var edits: [(Range<Int>, String)] = []
		for (s, plan) in zip(selections.all, plans) {
			switch plan {
			case .insert: edits.append((s.range, text))
			case .wrap:
				edits.append((s.range.lowerBound..<s.range.lowerBound, text))
				edits.append((s.range.upperBound..<s.range.upperBound, closeText))
			case .pair: edits.append((s.head..<s.head, text + closeText))
			case .over: break
			case .outdent(let range, let indent): edits.append((range, indent + text))
			}
		}
		let primary = selections.primaryIndex
		let after: (ChangeSet) -> SelectionSet = { cs in
			SelectionSet(zip(self.selections.all, plans).map { s, plan in
				switch plan {
				case .insert, .outdent: return Selection(caret: cs.map(s.range.upperBound, bias: .after))
				case .wrap:
					let lower = cs.map(s.range.lowerBound, bias: .after), upper = cs.map(s.range.upperBound, bias: .before)
					return s.isReversed ? Selection(anchor: upper, head: lower) : Selection(anchor: lower, head: upper)
				case .pair: return Selection(caret: cs.map(s.head, bias: .before) + 1)
				case .over: return Selection(caret: cs.map(s.head, bias: .after) + 1)
				}
			}, primary: primary)
		}
		if edits.isEmpty {
			setSelections(after(ChangeSet([])))
		} else {
			apply(ChangeSet(edits), kind: .typing, selectionsAfter: after)
		}
		return true
	}

	/// Range of an empty pair around the caret ("(|)", "'|'"), deleted together by Backspace.
	func emptyPair(around p: Int) -> Range<Int>? {
		guard language != nil, p > 0, let close = closing(for: byte(before: p)), byte(at: p) == close else { return nil }
		return (p - 1)..<(p + 1)
	}

	// MARK: Indentation

	/// Enter: keeps the line's indentation and adds a level after an opening bracket (or ":" in
	/// NEON); between a bracket pair the closing one moves to its own line.
	func insertNewlineSmart() {
		var plans: [(range: Range<Int>, text: String, caret: Int)] = [] // caret: bytes into text
		for s in selections.all {
			let p = s.range.lowerBound
			let lineStart = rope.offset(ofLine: rope.line(containing: p))
			let indent = String(decoding: rope.bytes(in: lineStart..<p).prefix { $0 == 0x20 || $0 == 0x09 }, as: UTF8.self)
			var before = p
			while before > lineStart && Bytes.isWhitespace(byte(before: before)) { before -= 1 }
			let prev = byte(before: before)
			let opens = language?.brackets.contains { $0.open == prev } ?? false
			let deeper = !inStringOrComment(before) && (opens || (language?.indentAfterColon == true && prev == 0x3A))
			var after = s.range.upperBound
			while after < rope.byteCount && byte(at: after) != 0x0A && Bytes.isWhitespace(byte(at: after)) { after += 1 }
			let first = "\n" + indent + (deeper ? indentUnit : "")
			if deeper, opens, byte(at: after) == closing(for: prev) {
				plans.append((p..<after, first + "\n" + indent, first.utf8.count))
			} else {
				plans.append((s.range, first, first.utf8.count))
			}
		}
		apply(ChangeSet(plans.map { ($0.range, $0.text) }), kind: .other) { cs in
			SelectionSet(plans.map { Selection(caret: cs.map($0.range.lowerBound, bias: .before) + $0.caret) }, primary: selections.primaryIndex)
		}
	}
}

extension Bytes {
	static func isWhitespace(_ b: UInt8) -> Bool { b == 0x20 || b == 0x09 || b == 0x0D }
	static func isIdentifier(_ b: UInt8) -> Bool {
		(b | 0x20 >= 0x61 && b | 0x20 <= 0x7A) || b == 0x5F || b >= 0x80 || (b >= 0x30 && b <= 0x39)
	}
}

/// Byte classes for the editor commands (the lexers have their own in Highlight).
enum Bytes {}
