/// Plain byte search over the rope, read in chunks so a 10 MB document is never copied whole.
nonisolated extension Rope {
	/// Non-overlapping matches of `needle` starting inside `range`, at most `limit` of them.
	/// With `wholeWord` a match must not touch word characters on either side.
	public func ranges(of needle: [UInt8], in range: Range<Int>? = nil, wholeWord: Bool = false,
	                   limit: Int = .max) -> [Range<Int>] {
		let range = range ?? 0..<byteCount
		guard !needle.isEmpty, limit > 0 else { return [] }
		let chunk = 1 << 16
		var found: [Range<Int>] = []
		var start = range.lowerBound
		var allowed = start
		while start < range.upperBound {
			let end = min(start + chunk, range.upperBound)
			let bytes = self.bytes(in: start..<min(end + needle.count - 1, byteCount))
			var i = bytes.startIndex
			while let r = bytes[i...].firstRange(of: needle), start + r.lowerBound < end {
				let match = (start + r.lowerBound)..<(start + r.upperBound)
				i = r.lowerBound + 1
				guard match.lowerBound >= allowed, !wholeWord || isWholeWord(match) else { continue }
				found.append(match)
				if found.count == limit { return found }
				allowed = match.upperBound
				i = r.upperBound
			}
			start = end
		}
		return found
	}

	/// First match at or after `offset`, wrapping around to the start of the document.
	public func nextRange(of needle: [UInt8], from offset: Int, wholeWord: Bool = false) -> Range<Int>? {
		ranges(of: needle, in: offset..<byteCount, wholeWord: wholeWord, limit: 1).first
			?? ranges(of: needle, in: 0..<min(offset, byteCount), wholeWord: wholeWord, limit: 1).first
	}

	/// True when no word character touches the range from either side.
	public func isWholeWord(_ range: Range<Int>) -> Bool {
		if let (s, _) = scalar(before: range.lowerBound), Rope.charClass(s) == .word { return false }
		if let (s, _) = scalar(at: range.upperBound), Rope.charClass(s) == .word { return false }
		return true
	}
}
