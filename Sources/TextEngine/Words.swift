/// Word movement: identifier characters form words, other punctuation runs form their own
/// words and whitespace (newlines included) is skipped.
extension Rope {
	public enum CharClass { case space, word, punctuation }

	public static func charClass(_ scalar: Unicode.Scalar) -> CharClass {
		if scalar.properties.isWhitespace { return .space }
		if scalar == "_" || scalar.properties.isAlphabetic || scalar.properties.numericType != nil { return .word }
		return .punctuation
	}

	/// Scalar starting at a scalar boundary and the offset after it.
	public func scalar(at offset: Int) -> (Unicode.Scalar, Int)? {
		guard offset < byteCount else { return nil }
		let end = min(offset + 4, byteCount)
		var it = bytes(in: offset..<end).makeIterator()
		var decoder = UTF8()
		guard case .scalarValue(let s) = decoder.decode(&it) else { return nil }
		return (s, offset + s.utf8.count)
	}

	/// Scalar ending at a scalar boundary and the offset where it starts.
	public func scalar(before offset: Int) -> (Unicode.Scalar, Int)? {
		guard offset > 0 else { return nil }
		let start = scalarBoundary(atOrBefore: offset - 1)
		return scalar(at: start).map { ($0.0, start) }
	}

	/// End of the next word after the offset (⌥→).
	public func wordEnd(after offset: Int) -> Int {
		var o = offset
		while let (s, next) = scalar(at: o), Rope.charClass(s) == .space { o = next }
		guard let (first, _) = scalar(at: o) else { return o }
		let kind = Rope.charClass(first)
		while let (s, next) = scalar(at: o), Rope.charClass(s) == kind { o = next }
		return o
	}

	/// Start of the word before the offset (⌥←).
	public func wordStart(before offset: Int) -> Int {
		var o = offset
		while let (s, prev) = scalar(before: o), Rope.charClass(s) == .space { o = prev }
		guard let (last, _) = scalar(before: o) else { return o }
		let kind = Rope.charClass(last)
		while let (s, prev) = scalar(before: o), Rope.charClass(s) == kind { o = prev }
		return o
	}
}
