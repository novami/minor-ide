import AppKit

/// Text-area accessibility as in NSTextView: ranges are UTF-16, lines are display rows
/// (a wrapped line is several), edits and caret moves are announced, and assistive apps
/// (Voice Control, VoiceOver) can change the selection and replace text.
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
		return accessibilityRow(of: caret)
	}

	public override func accessibilityLine(for index: Int) -> Int {
		accessibilityRow(of: rope.byteOffset(ofUTF16: min(max(0, index), rope.utf16Count)))
	}

	/// The row with the line break of its line, so moving through rows covers the text.
	public override func accessibilityRange(forLine row: Int) -> NSRange {
		accessibilityRowRange(row).map(utf16Range) ?? NSRange(location: NSNotFound, length: 0)
	}

	/// The editor draws one font and colours only syntax, so a line is one style run.
	public override func accessibilityStyleRange(for index: Int) -> NSRange {
		let line = rope.line(containing: rope.byteOffset(ofUTF16: min(max(0, index), rope.utf16Count)))
		let end = line + 1 < rope.lineCount ? rope.offset(ofLine: line + 1) : rope.byteCount
		return utf16Range(rope.offset(ofLine: line)..<end)
	}

	/// Voice Control and VoiceOver replace the primary selection; one undo step.
	public override func setAccessibilitySelectedText(_ string: String?) {
		let range = selections.primary.range
		apply(ChangeSet([(range, string ?? "")]), kind: .other) { cs in
			SelectionSet(caret: cs.map(range.upperBound, bias: .after))
		}
	}

	public override func setAccessibilityValue(_ value: Any?) {
		guard let string = value as? String else { return }
		apply(ChangeSet([(0..<rope.byteCount, string)]), kind: .other) { cs in
			SelectionSet(caret: min(cs.map(caret, bias: .before), rope.byteCount))
		}
	}

	/// Accessibility lines are display rows only while wrapping, else text lines.
	private var accessibilityUsesRows: Bool { !(wraps?.isEmpty ?? true) }

	func accessibilityRow(of offset: Int) -> Int {
		accessibilityUsesRows ? row(ofOffset: offset) : rope.line(containing: offset)
	}

	func accessibilityRowRange(_ row: Int) -> Range<Int>? {
		guard row >= 0 else { return nil }
		if !accessibilityUsesRows {
			guard row < rope.lineCount else { return nil }
			let end = row + 1 < rope.lineCount ? rope.offset(ofLine: row + 1) : rope.byteCount
			return rope.offset(ofLine: row)..<end
		}
		guard row < display.rowCount(lineCount: rope.lineCount) else { return nil }
		let (line, segment) = display.position(atRow: row)
		let b = breaks(ofLine: line)
		let start = segment == 0 ? rope.offset(ofLine: line) : offset(ofUnit: b[segment - 1], line: line)
		let end: Int
		if segment < b.count { end = offset(ofUnit: b[segment], line: line) }
		else { end = line + 1 < rope.lineCount ? rope.offset(ofLine: line + 1) : rope.byteCount }
		return start..<max(start, end)
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
	/// VoiceOver decides what to speak (the character, word or line reached) from the text
	/// state keys NSTextView sends too; without them it stays silent on caret moves.
	func postAccessibilityChange(edited: Bool) {
		defer { accessibilityMove = nil; accessibilityEdit = nil }
		guard accessibilityClientSeen else { return }
		if edited {
			// The edit's text lets VoiceOver speak what was typed or deleted.
			var editInfo: [NSAccessibility.NotificationUserInfoKey: Any]?
			if let edit = accessibilityEdit {
				var values: [[String: Any]] = []
				if !edit.deleted.isEmpty { values.append(["AXTextEditType": 1, "AXTextChangeValue": edit.deleted]) }
				if !edit.inserted.isEmpty { values.append(["AXTextEditType": edit.typed ? 3 : 2, "AXTextChangeValue": edit.inserted]) }
				editInfo = [.init(rawValue: "AXTextStateChangeType"): 1, .init(rawValue: "AXTextChangeValues"): values]
			}
			NSAccessibility.post(element: self, notification: .valueChanged, userInfo: editInfo)
		}
		var info: [NSAccessibility.NotificationUserInfoKey: Any] = [:]
		if let move = accessibilityMove, !edited {
			info[.init(rawValue: "AXTextStateChangeType")] = move.extend ? 3 : 2 // selection extend / move
			info[.init(rawValue: "AXTextSelectionDirection")] = move.direction.rawValue
			info[.init(rawValue: "AXTextSelectionGranularity")] = move.granularity.rawValue
		}
		NSAccessibility.post(element: self, notification: .selectedTextChanged, userInfo: info.isEmpty ? nil : info)
	}

	/// What kind of caret move a command made, from its selector name.
	static func accessibilityMove(for selector: Selector) -> AccessibilityMove? {
		let name = NSStringFromSelector(selector)
		guard name.hasPrefix("move") || name.hasPrefix("page") || name.hasPrefix("scrollPage") else { return nil }
		let extend = name.contains("ModifySelection")
		let back = ["Left", "Up", "Backward", "Beginning"].contains { name.contains($0) }
		let granularity: AccessibilityMove.Granularity
		if name.contains("Document") { granularity = .document }
		else if name.contains("Paragraph") { granularity = .paragraph }
		else if name.contains("OfLine") || name.contains("EndOfLine") { granularity = .line }
		else if name.contains("Word") { granularity = .word }
		else if name.contains("Up") || name.contains("Down") { granularity = .line }
		else if name.hasPrefix("page") || name.hasPrefix("scrollPage") { granularity = .page }
		else { granularity = .character }
		let boundary = name.contains("Beginning") || name.contains("EndOf") || name.contains("ToLeftEnd") || name.contains("ToRightEnd")
		let direction: AccessibilityMove.Direction = boundary ? (back ? .beginning : .end) : (back ? .previous : .next)
		return AccessibilityMove(extend: extend, direction: direction, granularity: granularity)
	}
}

/// Text of a single-range edit for its announcement (long text is cut, as speech would be).
struct AccessibilityEdit {
	var deleted: String
	var inserted: String
	var typed: Bool

	static let limit = 4096

	init?(_ changes: ChangeSet, in rope: Rope, kind: EditKind) {
		guard changes.changes.count == 1, let change = changes.changes.first else { return nil }
		let range = change.range.lowerBound..<min(change.range.upperBound, change.range.lowerBound + Self.limit)
		deleted = rope.string(in: rope.scalarBoundary(atOrBefore: range.lowerBound)..<rope.scalarBoundary(atOrBefore: range.upperBound))
		inserted = String(decoding: change.text.prefix(Self.limit), as: UTF8.self)
		typed = kind == .typing
	}
}

/// Values of the AXTextSelectionDirection and AXTextSelectionGranularity keys.
struct AccessibilityMove {
	enum Direction: Int { case beginning = 1, end, previous, next, discontiguous }
	enum Granularity: Int { case character = 1, word, line, sentence, paragraph, page, document, all }
	var extend: Bool
	var direction: Direction
	var granularity: Granularity
}
