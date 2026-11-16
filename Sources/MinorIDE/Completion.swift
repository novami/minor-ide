import AppKit
import EditorKit
import LSPKit
import MinorCore
import TextEngine

/// Completion in one editor pane (plan 3.4). A session starts when a word character or a trigger
/// character of the server is typed (not in strings and comments), or with ⌃Space / ⌥Esc; it lives
/// while the caret stays in the typed word. The list is filtered locally as the word grows and asked
/// again only when the server marked it incomplete. A result whose text has changed in another way
/// is dropped with its session. Return or Tab inserts the item (snippet with Tab stops, imports and
/// other additional edits in the same undo step), Esc closes the list.
@MainActor
final class CompletionController {
	private weak var editor: EditorView?
	private let endpoint: () -> (server: LanguageServer, uri: String)?

	private enum Trigger { case invoked, typed, character(UInt8) }

	private struct Session {
		let id: Int
		var trigger: Trigger
		let server: LanguageServer
		let uri: String
		let support: CompletionSupport
		/// Start of the word being completed; everything typed since goes in after it.
		let anchor: Int
		let line: Int
		/// Text and caret the current list was computed on (its ranges refer to them).
		var resultRope = Rope()
		var resultCaret = 0
		var list = CompletionList(.null)
		var shown: [Int] = []
		var selected = 0
		var inFlight: Task<Void, Never>?
		/// The text changed while an incomplete list was being asked for.
		var askAgain = false
	}

	private var session: Session?
	private var nextID = 0
	private var popup: CompletionPopup?
	private var observers: [NSObjectProtocol] = []

	init(editor: EditorView, endpoint: @escaping () -> (server: LanguageServer, uri: String)?) {
		self.editor = editor
		self.endpoint = endpoint
	}

	var isShowing: Bool { popup?.isVisible ?? false }

	// MARK: Editor events

	/// Text typed in the editor (after it went in).
	func typed(_ text: String) {
		guard session == nil, let editor, text.utf8.count == 1, let c = text.utf8.first,
		      editor.selections.all.count == 1, editor.selections.primary.isEmpty,
		      !editor.inStringOrComment(editor.caret), let end = endpoint(),
		      let support = end.server.completionSupport else { return }
		if support.triggerCharacters.contains(c) {
			start(.character(c), end, support)
		} else if Self.isWord(c) {
			start(.typed, end, support)
		}
	}

	/// After any change of the text: the session goes on while the caret is in its word.
	func textChanged() {
		guard session != nil else { return }
		guard isValid() else { return close() }
		if session!.list.isIncomplete { ask() }
		refilter()
	}

	func caretsChanged() {
		if session != nil, !isValid() { close() }
	}

	/// ⌃Space, ⌥Esc (Edit › Show Completions).
	func invoke() {
		close()
		guard let end = endpoint(), let support = end.server.completionSupport,
		      let editor, editor.selections.all.count == 1 else { return NSSound.beep() }
		start(.invoked, end, support)
	}

	/// Keys while the list shows: arrows, Page Up/Down, Return/Tab, Esc. Also ⌥Esc anytime.
	func handle(_ selector: Selector) -> Bool {
		if selector == #selector(NSResponder.complete(_:)) {
			invoke()
			return true
		}
		guard let popup, popup.isVisible, var s = session, !s.shown.isEmpty else { return false }
		let count = s.shown.count
		switch selector {
		case #selector(NSResponder.moveUp(_:)): s.selected = (s.selected - 1 + count) % count
		case #selector(NSResponder.moveDown(_:)): s.selected = (s.selected + 1) % count
		case #selector(NSResponder.pageUp(_:)), #selector(NSResponder.scrollPageUp(_:)):
			s.selected = max(0, s.selected - CompletionPopup.visibleRows)
		case #selector(NSResponder.pageDown(_:)), #selector(NSResponder.scrollPageDown(_:)):
			s.selected = min(count - 1, s.selected + CompletionPopup.visibleRows)
		case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertTab(_:)):
			accept(s.selected)
			return true
		case #selector(NSResponder.cancelOperation(_:)):
			close()
			return true
		default:
			return false
		}
		session = s
		popup.select(s.selected)
		resolveSelected()
		return true
	}

	func close() {
		session?.inFlight?.cancel()
		session = nil
		popup?.hide()
		for o in observers { NotificationCenter.default.removeObserver(o) }
		observers = []
	}

	// MARK: Session

	private func start(_ trigger: Trigger, _ end: (server: LanguageServer, uri: String), _ support: CompletionSupport) {
		guard let editor else { return }
		let caret = editor.caret
		var anchor = caret
		if case .character = trigger {} else {
			while anchor > 0, Self.isWord(editor.rope.byte(at: anchor - 1)) { anchor -= 1 }
		}
		nextID += 1
		session = Session(id: nextID, trigger: trigger, server: end.server, uri: end.uri, support: support,
		                  anchor: anchor, line: editor.rope.line(containing: caret))
		ask()
	}

	private func isValid() -> Bool {
		guard let s = session, let editor, editor.selections.all.count == 1, editor.selections.primary.isEmpty else { return false }
		let caret = editor.caret, rope = editor.rope
		guard caret >= s.anchor, caret - s.anchor <= 256, caret <= rope.byteCount, rope.line(containing: caret) == s.line else { return false }
		return rope.bytes(in: s.anchor..<caret).allSatisfy(Self.isWord)
	}

	/// Asks the server for the list at the caret; one request at a time.
	private func ask() {
		guard var s = session, let editor else { return }
		if s.inFlight != nil {
			s.askAgain = true
			session = s
			return
		}
		let rope = editor.rope, caret = editor.caret
		var context: JSONValue = ["triggerKind": 1]
		if s.list.isIncomplete {
			context = ["triggerKind": 3] // asking again for an incomplete list
		} else if case .character(let c) = s.trigger {
			context = ["triggerKind": 2, "triggerCharacter": .string(String(UnicodeScalar(c)))]
		}
		let params: JSONValue = [
			"textDocument": ["uri": .string(s.uri)],
			"position": rope.position(ofByte: caret, encoding: s.support.encoding).json,
			"context": context,
		]
		let id = s.id, server = s.server
		s.inFlight = Task { [weak self] in
			let result = try? await server.request("textDocument/completion", params)
			guard !Task.isCancelled else { return }
			self?.received(result, id: id, rope: rope, caret: caret)
		}
		session = s
	}

	private func received(_ result: JSONValue?, id: Int, rope: Rope, caret: Int) {
		guard var s = session, s.id == id else { return }
		s.inFlight = nil
		if let result {
			let old = s.shown.isEmpty ? nil : s.list.items[s.shown[s.selected]].label
			s.list = CompletionList(result)
			s.resultRope = rope
			s.resultCaret = caret
			s.shown = []
			s.selected = 0
			session = s
			refilter(keeping: old)
		} else {
			session = s
		}
		if session?.askAgain == true, session?.list.isIncomplete == true {
			session?.askAgain = false
			ask()
		}
	}

	/// Filters the list by the typed word and shows it (hidden when nothing matches).
	private func refilter(keeping label: String? = nil) {
		guard var s = session, let editor else { return }
		let previous = label ?? (s.shown.isEmpty ? nil : s.list.items[s.shown[s.selected]].label)
		let prefix = editor.rope.string(in: s.anchor..<editor.caret)
		s.shown = s.list.filtered(by: prefix)
		if let previous, let i = s.shown.firstIndex(where: { s.list.items[$0].label == previous }) {
			s.selected = i
		} else {
			s.selected = prefix.isEmpty ? (s.shown.firstIndex { s.list.items[$0].preselect } ?? 0) : 0
		}
		session = s
		guard !s.shown.isEmpty else {
			popup?.hide()
			return
		}
		show()
		resolveSelected()
	}

	private func show() {
		guard let s = session, let editor, let window = editor.window else { return }
		let popup = self.popup ?? CompletionPopup()
		self.popup = popup
		popup.onSelect = { [weak self] row in
			guard let self, var s = session, row < s.shown.count else { return }
			s.selected = row
			session = s
			resolveSelected()
		}
		popup.onAccept = { [weak self] row in self?.accept(row) }
		let rows = s.shown.map { CompletionPopup.Row(s.list.items[$0]) }
		let utf16 = editor.rope.utf16Offset(ofByte: s.anchor)
		let rect = editor.firstRect(forCharacterRange: NSRange(location: utf16, length: 0), actualRange: nil)
		popup.show(rows, selected: s.selected, docs: s.list.items[s.shown[s.selected]].documentation,
		           at: rect, parent: window, font: editor.font)
		if observers.isEmpty {
			let center = NotificationCenter.default
			let close: @Sendable (Notification) -> Void = { [weak self] _ in MainActor.assumeIsolated { self?.close() } }
			observers.append(center.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main, using: close))
			if let clip = editor.enclosingScrollView?.contentView {
				clip.postsBoundsChangedNotifications = true
				observers.append(center.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: .main, using: close))
			}
		}
	}

	/// Documentation and late details of the selected item (`completionItem/resolve`).
	private func resolveSelected() {
		guard let s = session, !s.shown.isEmpty else { return }
		let index = s.shown[s.selected], item = s.list.items[index]
		popup?.setDocs(item.documentation)
		guard s.support.resolves, !item.resolved else { return }
		session?.list.items[index].resolved = true // asked once
		let id = s.id, server = s.server, raw = item.raw
		Task { [weak self] in
			guard let json = try? await server.request("completionItem/resolve", raw) else { return }
			guard let self, var s = session, s.id == id, index < s.list.items.count else { return }
			s.list.items[index].merge(resolved: json)
			session = s
			if !s.shown.isEmpty, s.shown[s.selected] == index { popup?.setDocs(s.list.items[index].documentation) }
		}
	}

	private func accept(_ row: Int) {
		guard let s = session, let editor, row < s.shown.count else { return }
		let item = s.list.items[s.shown[row]]
		let rope = editor.rope, now = editor.caret
		let convert = { (r: LSPRange) -> Range<Int> in
			let old = s.resultRope.range(of: r, encoding: s.support.encoding)
			let lower = min(completionOffset(old.lowerBound, oldCaret: s.resultCaret, caret: now, isEnd: false), rope.byteCount)
			let upper = min(completionOffset(old.upperBound, oldCaret: s.resultCaret, caret: now, isEnd: true), rope.byteCount)
			return lower..<max(lower, upper)
		}
		var range = item.range.map(convert) ?? s.anchor..<now
		if !range.contains(now) && range.upperBound != now { range = s.anchor..<now }
		let extra = item.additionalTextEdits.map { (convert($0.range), $0.newText) }
		close()
		editor.insertSnippet(item.snippet, replacing: range, additionalEdits: extra)
	}

	static func isWord(_ b: UInt8) -> Bool {
		(0x30...0x39).contains(b) || (0x41...0x5A).contains(b) || (0x61...0x7A).contains(b) || b == 0x5F || b >= 0x80
	}
}
