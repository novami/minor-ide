import Foundation

/// What Find looks for. Plain text is matched literally; `regex` uses ICU syntax with ^ and $
/// at line boundaries. Whole word means no word character touches the match on either side.
public struct FindQuery: Sendable, Equatable {
	public var text: String
	public var regex: Bool
	public var caseSensitive: Bool
	public var wholeWord: Bool

	public init(text: String, regex: Bool = false, caseSensitive: Bool = false, wholeWord: Bool = false) {
		self.text = text
		self.regex = regex
		self.caseSensitive = caseSensitive
		self.wholeWord = wholeWord
	}

	func expression() throws -> NSRegularExpression {
		let pattern = regex ? text : NSRegularExpression.escapedPattern(for: text)
		var options: NSRegularExpression.Options = [.anchorsMatchLines]
		if !caseSensitive { options.insert(.caseInsensitive) }
		do {
			return try NSRegularExpression(pattern: pattern, options: options)
		} catch {
			throw FindError.invalidPattern
		}
	}

	/// Regex replacement templates understand \n and \t; $1 and \$ go to NSRegularExpression.
	static func expandEscapes(_ template: String) -> String {
		var out = ""
		var escaped = false
		for c in template {
			if escaped {
				switch c {
				case "n": out.append("\n")
				case "t": out.append("\t")
				default: out.append("\\"); out.append(c)
				}
				escaped = false
			} else if c == "\\" {
				escaped = true
			} else {
				out.append(c)
			}
		}
		if escaped { out.append("\\\\") }
		return out
	}

	/// Gives `text` the case pattern of `matched`: ALL CAPS, lower case or Capitalized.
	public static func applyingCase(of matched: String, to text: String) -> String {
		let letters = matched.filter(\.isLetter)
		guard let first = letters.first else { return text }
		if letters.count > 1 && letters.allSatisfy(\.isUppercase) { return text.uppercased() }
		if letters.allSatisfy(\.isLowercase) { return text.lowercased() }
		guard first.isUppercase, let i = text.firstIndex(where: \.isLetter) else { return text }
		return text[..<i] + text[i].uppercased() + text[text.index(after: i)...]
	}
}

public enum FindError: Error, Equatable {
	case invalidPattern
}

extension Rope {
	/// The text as an NSString for NSRegularExpression (UTF-16 storage, no Swift bridging cost).
	private func nsString(in range: Range<Int>) -> NSString {
		let bytes = self.bytes(in: range)
		return NSString(bytes: bytes, length: bytes.count, encoding: String.Encoding.utf8.rawValue) ?? ""
	}

	/// Sorted, non-overlapping, non-empty matches; at most `limit` of them.
	public func matches(of query: FindQuery, limit: Int = .max) throws -> [Range<Int>] {
		var found: [Range<Int>] = []
		try enumerateMatches(of: query) { range, _, _ in
			found.append(range)
			return found.count < limit
		}
		return found
	}

	/// Edits replacing every match, for one undoable Replace All.
	public func replacements(of query: FindQuery, with template: String, preserveCase: Bool) throws -> [(Range<Int>, String)] {
		var edits: [(Range<Int>, String)] = []
		let expanded = FindQuery.expandEscapes(template)
		try enumerateMatches(of: query) { range, result, text in
			var replacement = template
			if query.regex, let result, let text, let re = result.regularExpression {
				replacement = re.replacementString(for: result, in: text as String, offset: 0, template: expanded)
			}
			if preserveCase { replacement = FindQuery.applyingCase(of: string(in: range), to: replacement) }
			edits.append((range, replacement))
			return true
		}
		return edits
	}

	/// Replacement for one match found with `query`. A regex runs again on the match's lines,
	/// so $1 expands as it did in the whole text (look-behind past the line start excepted).
	public func replacement(for match: Range<Int>, query: FindQuery, template: String, preserveCase: Bool) throws -> String {
		var replacement = template
		if query.regex {
			let region = offset(ofLine: line(containing: match.lowerBound))..<lineRange(line(containing: match.upperBound)).upperBound
			let text = nsString(in: region)
			let start = utf16Offset(ofByte: match.lowerBound) - utf16Offset(ofByte: region.lowerBound)
			let length = utf16Offset(ofByte: match.upperBound) - utf16Offset(ofByte: match.lowerBound)
			let re = try query.expression()
			if let m = re.firstMatch(in: text as String, options: [.withTransparentBounds, .withoutAnchoringBounds],
			                         range: NSRange(location: start, length: text.length - start)),
			   m.range == NSRange(location: start, length: length) {
				replacement = re.replacementString(for: m, in: text as String, offset: 0, template: FindQuery.expandEscapes(template))
			}
		}
		return preserveCase ? FindQuery.applyingCase(of: string(in: match), to: replacement) : replacement
	}

	/// Calls `body` for each match with the regex result and the searched text (nil on the
	/// plain byte path); `body` returns false to stop.
	private func enumerateMatches(of query: FindQuery, _ body: (Range<Int>, NSTextCheckingResult?, NSString?) -> Bool) throws {
		guard !query.text.isEmpty else { return }
		if !query.regex && query.caseSensitive {
			for r in ranges(of: Array(query.text.utf8), wholeWord: query.wholeWord) where !body(r, nil, nil) { return }
			return
		}
		let re = try query.expression()
		let text = nsString(in: 0..<byteCount)
		re.enumerateMatches(in: text as String, range: NSRange(location: 0, length: text.length)) { m, _, stop in
			guard let m, m.range.length > 0 else { return }
			let range = byteOffset(ofUTF16: m.range.location)..<byteOffset(ofUTF16: m.range.location + m.range.length)
			if query.wholeWord && !isWholeWord(range) { return }
			if !body(range, m, text) { stop.pointee = true }
		}
	}
}

extension ChangeSet {
	/// Ranges moved through the edit; ranges an edit overlaps or inserts into are dropped.
	public func mapUntouched(_ ranges: [Range<Int>]) -> [Range<Int>] {
		var out: [Range<Int>] = []
		out.reserveCapacity(ranges.count)
		var i = 0, delta = 0
		for r in ranges {
			while i < changes.count && changes[i].range.upperBound <= r.lowerBound {
				// An insertion exactly at the start would land before the range: it only shifts it.
				delta += changes[i].text.count - changes[i].range.count
				i += 1
			}
			if i < changes.count && changes[i].range.lowerBound < r.upperBound { continue }
			out.append((r.lowerBound + delta)..<(r.upperBound + delta))
		}
		return out
	}
}
