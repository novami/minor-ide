import AppKit
import TextEngine

/// Basic text-area accessibility: VoiceOver reads the current line, the selection and
/// characters under the caret. Ranges are UTF-16, as in NSTextView. Full support is in 1f.
extension EditorView {
	public override func isAccessibilityElement() -> Bool { true }
	public override func accessibilityRole() -> NSAccessibility.Role? { .textArea }

	public override func accessibilityValue() -> Any? {
		accessibilityClientSeen = true
		return rope.string(in: 0..<rope.byteCount)
	}

	public override func accessibilityNumberOfCharacters() -> Int {
		accessibilityClientSeen = true
		return rope.utf16Count
	}

	public override func accessibilitySelectedText() -> String? {
		accessibilityClientSeen = true
		return rope.string(in: selections.primary.range)
	}

	public override func accessibilitySelectedTextRange() -> NSRange {
		accessibilityClientSeen = true
		return utf16Range(selections.primary.range)
	}

	public override func setAccessibilitySelectedTextRange(_ range: NSRange) {
		guard let bytes = byteRange(range) else { return }
		setSelections(SelectionSet([Selection(anchor: bytes.lowerBound, head: bytes.upperBound)]))
	}

	public override func accessibilitySelectedTextRanges() -> [NSValue]? {
		selections.all.map { NSValue(range: utf16Range($0.range)) }
	}

	public override func accessibilityInsertionPointLineNumber() -> Int {
		accessibilityClientSeen = true
		return rope.line(containing: caret)
	}

	public override func accessibilityLine(for index: Int) -> Int {
		rope.line(containing: rope.byteOffset(ofUTF16: min(max(0, index), rope.utf16Count)))
	}

	/// The line with its line break, so moving through lines covers the whole text.
	public override func accessibilityRange(forLine line: Int) -> NSRange {
		guard line >= 0, line < rope.lineCount else { return NSRange(location: NSNotFound, length: 0) }
		let end = line + 1 < rope.lineCount ? rope.offset(ofLine: line + 1) : rope.byteCount
		return utf16Range(rope.offset(ofLine: line)..<end)
	}

	public override func accessibilityString(for range: NSRange) -> String? {
		byteRange(range).map { rope.string(in: $0) }
	}

	public override func accessibilityAttributedString(for range: NSRange) -> NSAttributedString? {
		accessibilityString(for: range).map { NSAttributedString(string: $0, attributes: [.font: font]) }
	}

	public override func accessibilityFrame(for range: NSRange) -> NSRect {
		firstRect(forCharacterRange: range, actualRange: nil)
	}

	public override func accessibilityRange(for point: NSPoint) -> NSRange {
		NSRange(location: characterIndex(for: point), length: 1)
	}

	public override func accessibilityVisibleCharacterRange() -> NSRange {
		let visible = visibleRect.intersection(bounds)
		guard !visible.isEmpty else { return NSRange(location: 0, length: 0) }
		let first = line(atY: visible.minY)
		let last = line(atY: visible.maxY)
		let end = last + 1 < rope.lineCount ? rope.offset(ofLine: last + 1) : rope.byteCount
		return utf16Range(rope.offset(ofLine: first)..<end)
	}

	/// Tells assistive apps about edits and caret moves; free until one has asked us anything.
	func postAccessibilityChange(edited: Bool) {
		guard accessibilityClientSeen else { return }
		if edited { NSAccessibility.post(element: self, notification: .valueChanged) }
		NSAccessibility.post(element: self, notification: .selectedTextChanged)
	}
}
