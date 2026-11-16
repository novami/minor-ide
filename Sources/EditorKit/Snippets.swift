import AppKit
import TextEngine

/// Tab stops of an inserted snippet: Tab selects the next one, ⇧Tab the previous, the last
/// (`$0`) ends the session, as do Esc, Undo and a Tab with the caret outside the snippet.
struct SnippetSession {
	/// Absolute byte ranges, following edits.
	var stops: [[Range<Int>]]
	var index = 0

	mutating func map(through changes: ChangeSet) {
		stops = stops.map { $0.map { r in
			let lower = changes.map(r.lowerBound, bias: .before)
			return lower..<max(lower, changes.map(r.upperBound, bias: .after))
		} }
	}

	/// From the first stop's start to the furthest end.
	var span: ClosedRange<Int> {
		let all = stops.joined()
		return (all.map(\.lowerBound).min() ?? 0)...(all.map(\.upperBound).max() ?? 0)
	}
}

extension EditorView {
	/// Replaces `range` with the snippet (indented like the current line) and applies `additionalEdits`
	/// (which must not overlap it) as one undo step; selects the first tab stop.
	public func insertSnippet(_ snippet: Snippet, replacing range: Range<Int>, additionalEdits: [(Range<Int>, String)] = []) {
		let lineStart = rope.offset(ofLine: rope.line(containing: range.lowerBound))
		let indent = String(decoding: rope.bytes(in: lineStart..<range.lowerBound).prefix { $0 == 0x20 || $0 == 0x09 }, as: UTF8.self)
		let snippet = snippet.indented(indent)
		let extra = additionalEdits.filter { $0.0.upperBound <= range.lowerBound || $0.0.lowerBound >= range.upperBound }
		// Where the snippet starts after the edit: shifted by the extra edits in front of it.
		let base = range.lowerBound + extra.filter { $0.0.upperBound <= range.lowerBound }
			.reduce(0) { $0 + $1.1.utf8.count - $1.0.count }
		let stops = snippet.stops.map { $0.map { (base + $0.lowerBound)..<(base + $0.upperBound) } }
		snippetSession = nil
		apply(ChangeSet(extra + [(range, snippet.text)]), kind: .other) { _ in Self.selections(stops[0]) }
		if stops.count > 1 { snippetSession = SnippetSession(stops: stops) }
	}

	/// Edit › Show Completions (⌃Space); ⌥Esc arrives as the `complete:` command.
	@objc public func showCompletions(_ sender: Any?) {
		if commandInterceptor?(#selector(NSResponder.complete(_:))) != true { NSSound.beep() }
	}

	/// Whether a snippet is being filled in.
	public var isInSnippet: Bool { snippetSession != nil }

	private static func selections(_ ranges: [Range<Int>]) -> SelectionSet {
		SelectionSet(ranges.map { Selection(anchor: $0.lowerBound, head: $0.upperBound) })
	}

	/// Tab, ⇧Tab and Esc while a snippet session runs; false lets the editor handle the key.
	func snippetCommand(_ selector: Selector) -> Bool {
		guard var session = snippetSession else { return false }
		switch selector {
		case #selector(insertTab(_:)), #selector(insertBacktab(_:)):
			guard session.span.contains(caret) else {
				snippetSession = nil
				return false
			}
			let forward = selector == #selector(insertTab(_:))
			session.index = max(0, session.index + (forward ? 1 : -1))
			setSelections(Self.selections(session.stops[min(session.index, session.stops.count - 1)]))
			snippetSession = session.index >= session.stops.count - 1 ? nil : session
			scrollCaretVisible()
			return true
		case #selector(cancelOperation(_:)):
			snippetSession = nil
			return false
		default:
			return false
		}
	}
}
