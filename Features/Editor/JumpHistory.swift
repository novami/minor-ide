import AppKit

/// A place for Back and Forward; in an open file it follows edits (an anchor).
@MainActor
final class JumpPlace {
	let url: URL
	private weak var doc: FileDocument?
	private var anchor: AnchorID?
	private var saved: Int

	init(url: URL, doc: FileDocument, offset: Int) {
		self.url = url.standardizedFileURL
		self.doc = doc
		saved = offset
		anchor = doc.text.anchors.add(at: offset)
	}

	var offset: Int {
		if let doc, let anchor, let now = doc.text.anchors.offset(of: anchor) { return now }
		return saved
	}

	/// The line in the open file; the offset when the file was closed since.
	var line: Int { doc.map { $0.text.rope.line(containing: min(offset, $0.text.rope.byteCount)) } ?? -offset - 1 }

	func release() {
		if let doc, let anchor { doc.text.anchors.remove(anchor) }
		anchor = nil
	}

	/// The same line of the same file counts as one place.
	static func same(_ a: JumpPlace, _ b: JumpPlace) -> Bool { a.url == b.url && a.line == b.line }
}

/// Back and Forward of one project's windows (plan 3.6): jumps to definitions, usages, Open
/// Quickly and search results record where they started.
@MainActor
final class JumpHistory {
	private var history = NavigationHistory<JumpPlace>()

	var canGoBack: Bool { history.canGoBack }
	var canGoForward: Bool { history.canGoForward }

	/// Before a jump away from the focused place of `window`.
	func record(from window: DocumentWindow) {
		guard let place = Self.current(window) else { return }
		release(history.record(place, same: JumpPlace.same))
	}

	func goBack(in window: DocumentWindow) { go(window) { $0.goBack(from: $1, same: JumpPlace.same) } }
	func goForward(in window: DocumentWindow) { go(window) { $0.goForward(from: $1, same: JumpPlace.same) } }

	private func go(_ window: DocumentWindow,
	                _ step: (inout NavigationHistory<JumpPlace>, JumpPlace) -> (place: JumpPlace?, dropped: [JumpPlace])) {
		guard let current = Self.current(window) else { return NSSound.beep() }
		let (target, dropped) = step(&history, current)
		release(dropped)
		guard let target else {
			current.release()
			return NSSound.beep()
		}
		let caret = target.offset..<target.offset
		(NSApp.delegate as? AppDelegate)?.open(target.url, range: caret, from: window.project)
	}

	private func release(_ places: [JumpPlace]) { places.forEach { $0.release() } }

	private static func current(_ window: DocumentWindow) -> JumpPlace? {
		let pane = window.focusedPane
		guard let url = pane.document.url else { return nil }
		return JumpPlace(url: url, doc: pane.document, offset: pane.editor.caret)
	}
}
