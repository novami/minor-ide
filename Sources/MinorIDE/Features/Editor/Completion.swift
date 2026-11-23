import AppKit
import Localization
import EditorKit
import LSPKit
import MinorCore
import TextEngine

/// Completion in one editor pane (plan 3.4). A session starts when a word character (not a digit)
/// or a trigger character of the server is typed outside strings and comments, or with ⌃Space /
/// ⌥Esc; it lives while the caret stays in the typed word. The list is filtered locally as the word
/// grows and asked again only when the server marked it incomplete. A result whose text changed in
/// another way is dropped with its session. Return or Tab inserts the item at every caret (snippet
/// with Tab stops, imports and other additional edits in the same undo step), a commit character of
/// the item inserts it and then itself, Esc closes the list.
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
		/// Follows edits: an edit in front of the word moves it, which ends the session.
		let anchorID: AnchorID
		let line: Int
		/// Text and caret the current list was computed on (its ranges refer to them).
		var resultRope = Rope()
		var resultCaret = 0
		var list = CompletionList(.null)
		/// Counts the lists of the session: a late resolve must not land in a newer list.
		var generation = 0
		var shown: [Int] = []
		var selected = 0
		var inFlight: Task<Void, Never>?
		/// The text changed while an incomplete list was being asked for.
		var askAgain = false
		/// `completionItem/resolve` requests by item index (of the current generation).
		var resolving: [Int: Task<JSONValue?, Never>] = [:]
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

	/// Before typed text goes in: a commit character of the selected item accepts it.
	func willType(_ text: String) {
		guard let popup, popup.isVisible, let s = session, !s.shown.isEmpty, text.utf8.count == 1,
		      let c = text.utf8.first, s.list.items[s.shown[s.selected]].commitCharacters.contains(c) else { return }
		accept(s.selected, plain: true)
	}

	/// Text typed in the editor (after it went in).
	func typed(_ text: String) {
		guard session == nil, let editor, text.utf8.count == 1, let c = text.utf8.first,
		      editor.selections.all.allSatisfy(\.isEmpty), !editor.typedInStringOrComment(editor.caret),
		      let end = endpoint(), let support = end.server.completionSupport else { return }
		if support.triggerCharacters.contains(c) {
			start(.character(c), end, support)
		} else if Self.isWord(c), let first = wordStart(), !(0x30...0x39).contains(editor.rope.byte(at: first)) {
			start(.typed, end, support)
		}
	}

	/// After any change of the text: the session goes on while the caret is in its word.
	func textChanged() {
		guard let current = session else { return }
		guard isValid() else { return close() }
		if current.list.isIncomplete { ask() }
		refilter()
	}

	func caretsChanged() {
		if session != nil, !isValid() { close() }
	}

	/// ⌃Space, ⌥Esc (Edit › Show Completions).
	func invoke() {
		close()
		guard let end = endpoint(), let support = end.server.completionSupport,
		      let editor, editor.selections.all.allSatisfy(\.isEmpty) else { return NSSound.beep() }
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
		selectionChanged()
		return true
	}

	func close() {
		if let s = session {
			s.inFlight?.cancel()
			editor?.anchors.remove(s.anchorID)
		}
		session = nil
		popup?.hide()
		for o in observers { NotificationCenter.default.removeObserver(o) }
		observers = []
	}

	// MARK: Session

	private func wordStart() -> Int? {
		guard let editor else { return nil }
		var start = editor.caret
		while start > 0, Self.isWord(editor.rope.byte(at: start - 1)) { start -= 1 }
		return start < editor.caret ? start : nil
	}

	private func start(_ trigger: Trigger, _ end: (server: LanguageServer, uri: String), _ support: CompletionSupport) {
		guard let editor else { return }
		let caret = editor.caret
		var anchor = caret
		if case .character = trigger {} else { anchor = wordStart() ?? caret }
		nextID += 1
		let anchorID = editor.anchors.add(at: anchor, bias: .before)
		session = Session(id: nextID, trigger: trigger, server: end.server, uri: end.uri, support: support,
		                  anchor: anchor, anchorID: anchorID, line: editor.rope.line(containing: caret))
		ask()
	}

	private func isValid() -> Bool {
		guard let s = session, let editor, editor.selections.all.allSatisfy(\.isEmpty),
		      editor.anchors.offset(of: s.anchorID) == s.anchor else { return false }
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
			s.generation += 1
			s.resolving = [:]
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
		let changed = s.shown.isEmpty || previous != s.list.items[s.shown[s.selected]].label
		session = s
		guard !s.shown.isEmpty else {
			popup?.hide()
			return
		}
		let wasVisible = isShowing
		show()
		if changed || !wasVisible { selectionChanged() }
	}

	private func show() {
		guard let s = session, let editor, let window = editor.window else { return }
		let popup = self.popup ?? CompletionPopup()
		self.popup = popup
		popup.onSelect = { [weak self] row in
			guard let self, var s = session, row < s.shown.count, row != s.selected else { return }
			s.selected = row
			session = s
			selectionChanged()
		}
		popup.onAccept = { [weak self] row in self?.accept(row) }
		let rows = s.shown.map { CompletionPopup.Row(s.list.items[$0]) }
		popup.show(rows, selected: s.selected, docs: s.list.items[s.shown[s.selected]].documentation,
		           at: anchorRect(), parent: window, font: editor.font)
		if observers.isEmpty {
			let center = NotificationCenter.default
			observers.append(center.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in
				MainActor.assumeIsolated { self?.close() }
			})
			// Scrolling moves the list with the word; it hides while the word is out of view.
			if let clip = editor.enclosingScrollView?.contentView {
				clip.postsBoundsChangedNotifications = true
				observers.append(center.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: .main) { [weak self] _ in
					MainActor.assumeIsolated { self?.followScroll() }
				})
			}
		}
	}

	/// Screen rect of the word's start.
	private func anchorRect() -> NSRect {
		guard let s = session, let editor else { return .zero }
		let utf16 = editor.rope.utf16Offset(ofByte: s.anchor)
		return editor.firstRect(forCharacterRange: NSRange(location: utf16, length: 0), actualRange: nil)
	}

	private func followScroll() {
		guard let popup, session?.shown.isEmpty == false, let editor, let window = editor.window,
		      let clip = editor.enclosingScrollView?.contentView else { return }
		let rect = anchorRect()
		let visible = window.convertToScreen(clip.convert(clip.bounds, to: nil))
		if visible.contains(NSPoint(x: rect.minX, y: rect.midY)) { popup.move(to: rect) } else { popup.hide() }
	}

	/// The selected item changed: its documentation, a resolve for it and a spoken announcement.
	private func selectionChanged() {
		guard let s = session, !s.shown.isEmpty else { return }
		let index = s.shown[s.selected], item = s.list.items[index]
		popup?.setDocs(item.documentation)
		announce(item, position: s.selected + 1, of: s.shown.count)
		_ = resolve(index)
	}

	/// Starts (once) `completionItem/resolve` for an item; the task delivers the merged item's JSON.
	private func resolve(_ index: Int) -> Task<JSONValue?, Never>? {
		guard var s = session, s.support.resolves, index < s.list.items.count, !s.list.items[index].resolved else {
			return session?.resolving[index]
		}
		if let running = s.resolving[index] { return running }
		let id = s.id, generation = s.generation, server = s.server, raw = s.list.items[index].raw
		let task = Task<JSONValue?, Never> { [weak self] in
			let json = try? await server.request("completionItem/resolve", raw)
			if let json, let self, var s = session, s.id == id, s.generation == generation {
				s.list.items[index].merge(resolved: json)
				s.resolving[index] = nil
				session = s
				if !s.shown.isEmpty, s.shown[s.selected] == index { popup?.setDocs(s.list.items[index].documentation) }
			}
			return json
		}
		s.resolving[index] = task
		session = s
		return task
	}

	/// `plain`: a commit character accepts; the snippet goes in as text, the caret after it.
	private func accept(_ row: Int, plain: Bool = false) {
		guard let s = session, let editor, row < s.shown.count else { return }
		let index = s.shown[row], item = s.list.items[index]
		let rope = editor.rope, now = editor.caret
		let convert = { (r: LSPRange) -> Range<Int> in
			let old = s.resultRope.range(of: r, encoding: s.support.encoding)
			let lower = min(completionOffset(old.lowerBound, oldCaret: s.resultCaret, caret: now, isEnd: false), rope.byteCount)
			let upper = min(completionOffset(old.upperBound, oldCaret: s.resultCaret, caret: now, isEnd: true), rope.byteCount)
			return lower..<max(lower, upper)
		}
		var range = item.range.map(convert) ?? s.anchor..<now
		if !range.contains(now) && range.upperBound != now { range = s.anchor..<now }
		// Other carets: the same typed word in front of them is replaced too.
		let prefix = Array(rope.bytes(in: s.anchor..<now))
		var ranges = [range]
		for sel in editor.selections.all where sel.head != now {
			let c = sel.head, start = c - prefix.count
			let typed = start >= 0 && Array(rope.bytes(in: start..<c)) == prefix
			ranges.append(typed ? start..<c : c..<c)
		}
		ranges.sort { $0.lowerBound < $1.lowerBound }
		if zip(ranges, ranges.dropFirst()).contains(where: { $0.upperBound > $1.lowerBound }) { ranges = [range] }
		let extra = item.additionalTextEdits.map { (convert($0.range), $0.newText) }
		// An item still being resolved may bring its imports late: they join the same undo step.
		let pending = item.resolved || !s.support.resolves || !item.additionalTextEdits.isEmpty ? nil : resolve(index)
		let resultRope = s.resultRope, encoding = s.support.encoding, front = ranges[0].lowerBound
		close()
		let snippet = plain ? Snippet(text: item.snippet.text) : item.snippet
		editor.insertSnippet(snippet, replacing: ranges, additionalEdits: extra)
		guard let pending else { return }
		let version = editor.document.version
		Task { [weak editor] in
			guard let json = await pending.value, let editor, editor.document.version == version else { return }
			// Only edits in front of the completed word: that text has not changed since the result.
			let late = (json["additionalTextEdits"]?.arrayValue ?? []).compactMap { TextEdit($0) }
				.map { (resultRope.range(of: $0.range, encoding: encoding), $0.newText) }
				.filter { $0.0.upperBound <= front }
			if !late.isEmpty { editor.replaceJoiningUndo(late) }
		}
	}

	private func announce(_ item: CompletionItem, position: Int, of count: Int) {
		guard NSWorkspace.shared.isVoiceOverEnabled else { return }
		let text = [item.label, item.detail].compactMap { $0 }.joined(separator: ", ") + ", " + Strings.common.indexOfTotal(index: position, total: count)
		NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
		                     userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
	}

	static func isWord(_ b: UInt8) -> Bool {
		(0x30...0x39).contains(b) || (0x41...0x5A).contains(b) || (0x61...0x7A).contains(b) || b == 0x5F || b >= 0x80
	}
}
