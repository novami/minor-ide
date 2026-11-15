import AppKit
import TextEngine

/// Find and replace in one document; selections go to `editor`, highlights to all its editors. Searches run off the main thread on a snapshot of the
/// rope; a newer query or edit discards older results.
@MainActor
public final class FindController {
	/// The editor that gets the selected match (the focused pane of a split).
	/// A pane showing another file drops the old file's highlights and searches again.
	public var editor: EditorView {
		didSet {
			guard editor.document !== oldValue.document else { return }
			for view in oldValue.document.views { view.setFindMatches([]) }
			invalidate()
			if showsHighlights { refresh() } else { onUpdate?() }
		}
	}
	public var query = FindQuery(text: "") {
		didSet { if query != oldValue { refresh() } }
	}
	public var replacement = ""
	public var preserveCase = false
	/// Highlights are shown only while the find bar is open.
	public var showsHighlights = false {
		didSet { highlight(showsHighlights ? matches : []) }
	}
	/// After a new query the first match at or after this offset gets selected (incremental find).
	public var origin: Int?

	public private(set) var matches: [Range<Int>] = []
	public private(set) var error: FindError?
	/// Called when matches, the error or the current match change.
	public var onUpdate: (() -> Void)?

	private var search: Task<Void, Never>?
	private var generation = 0

	public init(editor: EditorView) {
		self.editor = editor
	}

	private func highlight(_ ranges: [Range<Int>]) {
		for view in editor.document.views { view.setFindMatches(ranges) }
	}

	/// Index of the match the primary selection covers.
	public var currentIndex: Int? {
		let range = editor.selections.primary.range
		let i = lowerIndex(range.lowerBound)
		return i < matches.count && matches[i] == range ? i : nil
	}

	/// Starts a new search; text changes call this too. `delay` coalesces fast typing.
	public func refresh(delay: Duration = .zero) {
		search?.cancel()
		generation += 1
		let generation = generation, rope = editor.rope, query = query
		search = Task { [weak self] in
			if delay > .zero { try? await Task.sleep(for: delay) }
			guard !Task.isCancelled else { return }
			let result = await Task.detached(priority: .userInitiated) { () -> Result<[Range<Int>], FindError> in
				do { return .success(try rope.matches(of: query)) } catch { return .failure(error as? FindError ?? .invalidPattern) }
			}.value
			guard let self, generation == self.generation else { return }
			switch result {
			case .success(let found):
				matches = found
				error = nil
			case .failure(let e):
				matches = []
				error = e
			}
			if showsHighlights { highlight(matches) }
			if let origin {
				self.origin = nil
				if let first = matches.isEmpty ? nil : matches[lowerIndex(origin) % matches.count] { select(first) }
			}
			onUpdate?()
		}
	}

	/// Drops results after an edit while the bar is closed; the next ⌘G searches again.
	public func invalidate() {
		search?.cancel()
		generation += 1
		matches = []
		error = nil
	}

	/// Waits for the search in flight, if any.
	public func waitForResults() async {
		await search?.value
	}

	/// ⌘G / ⇧⌘G: selects the next or previous match, wrapping around.
	public func findNext(forward: Bool = true) async {
		await waitForResults()
		guard !matches.isEmpty else { NSSound.beep(); return }
		let s = editor.selections.primary.range
		let i = forward ? lowerIndex(s.upperBound) % matches.count
			: (lowerIndex(s.lowerBound) + matches.count - 1) % matches.count
		select(matches[i])
		onUpdate?()
	}

	/// Replaces the selected match and moves to the next one; elsewhere it only moves.
	public func replaceAndFind() async {
		await waitForResults()
		if let i = currentIndex {
			let match = matches[i]
			guard let text = try? editor.rope.replacement(for: match, query: query, template: replacement, preserveCase: preserveCase)
			else { return }
			editor.replace(match, with: text)
			// Search again so the next match comes from the edited text.
			refresh()
			await waitForResults()
		}
		await findNext()
	}

	/// Replaces every match as one undo step; returns how many were replaced.
	@discardableResult
	public func replaceAll() async -> Int {
		await waitForResults()
		guard let edits = try? editor.rope.replacements(of: query, with: replacement, preserveCase: preserveCase),
		      !edits.isEmpty else { return 0 }
		editor.replace(edits)
		refresh()
		await waitForResults()
		return edits.count
	}

	/// ⌘E: the selected text becomes the query (literal, so a regex query turns plain).
	public func useSelection() {
		let s = editor.selections.primary
		guard !s.isEmpty else { return }
		query.text = editor.rope.string(in: s.range)
		query.regex = false
	}

	private func select(_ match: Range<Int>) {
		editor.setSelections(SelectionSet([Selection(anchor: match.lowerBound, head: match.upperBound)]))
	}

	/// First match starting at or after `offset` (count when none).
	private func lowerIndex(_ offset: Int) -> Int {
		var lo = 0, hi = matches.count
		while lo < hi {
			let mid = (lo + hi) / 2
			if matches[mid].lowerBound < offset { lo = mid + 1 } else { hi = mid }
		}
		return lo
	}
}
