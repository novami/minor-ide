/// Text with tab stops, parsed from the snippet syntax of completion items: `$1`, `${1}`,
/// `${1:placeholder}` (placeholders nest), `${1|one,two|}` (the first choice), `$0` (final caret),
/// variables `$name` / `${name:default}` (unknown, so the default or nothing), transforms (ignored).
/// `\` escapes `$`, `}` and `\`; a `$` that starts nothing is literal.
nonisolated public struct Snippet: Sendable, Equatable {
	public var text: String
	/// Byte ranges in `text` to visit with Tab: `$1`, `$2`, … in order, then `$0` (or the end of
	/// the text). A stop used several times has several ranges, edited together.
	public var stops: [[Range<Int>]]

	/// Plain text: the caret ends after it.
	public init(text: String) {
		self.text = text
		stops = [[text.utf8.count..<text.utf8.count]]
	}

	public init(parsing source: String) {
		var parser = Parser(bytes: Array(source.utf8))
		var out: [UInt8] = []
		var found: [(Int, Range<Int>)] = []
		parser.parse(&out, &found, nested: false)
		text = String(decoding: out, as: UTF8.self)
		var byIndex: [Int: [Range<Int>]] = [:]
		for (index, range) in found { byIndex[index, default: []].append(range) }
		stops = byIndex.keys.filter { $0 > 0 }.sorted().compactMap { byIndex[$0] }
		stops.append(byIndex[0] ?? [out.count..<out.count])
	}

	/// Every line after the first gets `indent` in front (the snippet follows the line it is inserted on).
	public func indented(_ indent: String) -> Snippet {
		guard !indent.isEmpty, text.utf8.contains(0x0A) else { return self }
		let pad = Array(indent.utf8)
		var out: [UInt8] = []
		var newlinesBefore: [Int] = [] // newlinesBefore[i]: newlines in text[..<i]
		var count = 0
		for b in text.utf8 {
			newlinesBefore.append(count)
			out.append(b)
			if b == 0x0A { out += pad; count += 1 }
		}
		newlinesBefore.append(count)
		let shift = { (o: Int) in o + newlinesBefore[o] * pad.count }
		var copy = self
		copy.text = String(decoding: out, as: UTF8.self)
		copy.stops = stops.map { $0.map { shift($0.lowerBound)..<shift($0.upperBound) } }
		return copy
	}

	private struct Parser {
		let bytes: [UInt8]
		var i = 0

		/// Copies text until the end, or until an unescaped `}` when `nested` (left for the caller).
		mutating func parse(_ out: inout [UInt8], _ found: inout [(Int, Range<Int>)], nested: Bool) {
			while i < bytes.count {
				let c = bytes[i]
				if c == 0x5C, i + 1 < bytes.count, [0x24, 0x7D, 0x5C].contains(bytes[i + 1]) { // \$ \} \\
					out.append(bytes[i + 1])
					i += 2
					continue
				}
				if nested, c == 0x7D { return }
				if c == 0x24, dollar(&out, &found) { continue }
				out.append(c)
				i += 1
			}
		}

		/// A `$` construct at `i`; false (with `i` unchanged) when it is a plain dollar sign.
		mutating func dollar(_ out: inout [UInt8], _ found: inout [(Int, Range<Int>)]) -> Bool {
			let start = i
			i += 1
			if let n = number() {
				found.append((n, out.count..<out.count))
				return true
			}
			if name() { return true }
			guard i < bytes.count, bytes[i] == 0x7B else { i = start; return false } // {
			i += 1
			if let n = number() {
				let from = out.count
				guard i < bytes.count else { i = start; return false }
				switch bytes[i] {
				case 0x7D: i += 1 // }
				case 0x3A: // :
					i += 1
					parse(&out, &found, nested: true)
					if i < bytes.count { i += 1 }
				case 0x7C: // |
					i += 1
					out += choice()
				case 0x2F: skipTransform() // /
				default: i = start; return false
				}
				found.append((n, from..<out.count))
				return true
			}
			guard name(), i < bytes.count else { i = start; return false }
			switch bytes[i] {
			case 0x7D: i += 1
			case 0x3A:
				i += 1
				parse(&out, &found, nested: true)
				if i < bytes.count { i += 1 }
			case 0x2F: skipTransform()
			default: i = start; return false
			}
			return true
		}

		mutating func number() -> Int? {
			var n: Int?
			while i < bytes.count, (0x30...0x39).contains(bytes[i]) {
				n = (n ?? 0) * 10 + Int(bytes[i] - 0x30)
				i += 1
			}
			return n
		}

		mutating func name() -> Bool {
			guard i < bytes.count, bytes[i] == 0x5F || isLetter(bytes[i]) else { return false }
			while i < bytes.count, bytes[i] == 0x5F || isLetter(bytes[i]) || (0x30...0x39).contains(bytes[i]) { i += 1 }
			return true
		}

		func isLetter(_ b: UInt8) -> Bool { (0x41...0x5A).contains(b) || (0x61...0x7A).contains(b) }

		/// `a,b|}` after `${n|`: the first choice.
		mutating func choice() -> [UInt8] {
			var first: [UInt8] = [], done = false
			while i < bytes.count {
				let c = bytes[i]
				if c == 0x5C, i + 1 < bytes.count { if !done { first.append(bytes[i + 1]) }; i += 2; continue }
				if c == 0x7C, i + 1 < bytes.count, bytes[i + 1] == 0x7D { i += 2; break }
				if c == 0x2C { done = true } else if !done { first.append(c) }
				i += 1
			}
			return first
		}

		/// `/regex/format/options}`: skipped up to the closing brace.
		mutating func skipTransform() {
			while i < bytes.count {
				if bytes[i] == 0x5C { i += 2; continue }
				if bytes[i] == 0x7D { i += 1; return }
				i += 1
			}
		}
	}
}
