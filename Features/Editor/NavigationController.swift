import AppKit

/// A place a jump leads to, with its line for menus and the Usages panel.
nonisolated struct NavigationTarget: Sendable {
	let url: URL
	/// Byte range in the file's text.
	let range: Range<Int>
	/// The line, cut around the range when long (`line.ranges` marks the range in it).
	let line: FileSearchLine

	/// Converts locations: files open in an editor from their text, the rest read from disk.
	/// Sorted by path and position, duplicates dropped.
	@MainActor static func resolve(_ locations: [Location], encoding: PositionEncoding) async -> [NavigationTarget] {
		var open: [URL: Rope] = [:]
		for url in Set(locations.compactMap(\.url)) {
			if let doc = FileDocument.document(for: url) { open[url] = doc.text.rope }
		}
		return await Task.detached(priority: .userInitiated) {
			var ropes = open
			var targets: [NavigationTarget] = []
			for location in Set(locations) {
				guard let url = location.url else { continue }
				let rope: Rope
				if let known = ropes[url] {
					rope = known
				} else {
					guard let data = try? Data(contentsOf: url) else { continue }
					rope = Rope(bytes: [UInt8](data))
					ropes[url] = rope
				}
				targets.append(target(url, rope, location.range, encoding))
			}
			return targets.sorted { ($0.url.path, $0.range.lowerBound) < ($1.url.path, $1.range.lowerBound) }
		}.value
	}

	private static func target(_ url: URL, _ rope: Rope, _ range: LSPRange, _ encoding: PositionEncoding) -> NavigationTarget {
		NavigationTarget(url: url, bytes: rope.range(of: range, encoding: encoding), in: rope)
	}

	/// The target of a byte range of `rope` (the file's current text).
	init(url: URL, bytes: Range<Int>, in rope: Rope) {
		let line = rope.line(containing: bytes.lowerBound)
		var lineRange = rope.lineRange(line)
		while lineRange.upperBound > lineRange.lowerBound, [0x0A, 0x0D].contains(rope.byte(at: lineRange.upperBound - 1)) {
			lineRange = lineRange.lowerBound..<(lineRange.upperBound - 1)
		}
		// A long line is cut around the range.
		let from = rope.scalarBoundary(atOrBefore: max(lineRange.lowerBound, bytes.lowerBound - 80))
		let to = rope.scalarBoundary(atOrBefore: min(lineRange.upperBound, max(bytes.upperBound, from) + 160))
		let marked = (bytes.lowerBound - from)..<(min(bytes.upperBound, to) - from)
		self.url = url
		range = bytes
		self.line = FileSearchLine(line: line, column: from - lineRange.lowerBound, text: rope.string(in: from..<to), ranges: [marked])
	}
}

/// Jumps from one editor pane (plan 3.5): ⌘+click or a middle click on a symbol goes to its
/// definition, on the declaration itself to its usages; while ⌘ is held, a symbol with a
/// definition is underlined. Several targets show as a menu at the symbol. Navigate menu:
/// definition, implementation, type definition at the caret, usages into the Usages panel.
@MainActor
final class NavigationController {
	private weak var editor: EditorView?
	private let endpoint: () -> (server: LanguageServer, uri: String)?
	/// Shows usages in the Usages panel of the window: the symbol's name and the search.
	var showUsages: ((String, @escaping @MainActor () async -> [NavigationTarget]?) -> Void)?
	private var hoverTask: Task<Void, Never>?
	/// Definitions found for the hovered word: a click on it jumps without asking again.
	private var known: (range: Range<Int>, version: Int, locations: [Location])?
	/// Counts jumps: a slow answer must not jump after the user started another one.
	private var generation = 0

	init(editor: EditorView, endpoint: @escaping () -> (server: LanguageServer, uri: String)?) {
		self.editor = editor
		self.endpoint = endpoint
		editor.onNavigate = { [weak self] in self?.click(at: $0) ?? false }
		editor.onLinkHover = { [weak self] in self?.hover($0) }
	}

	func supports(_ kind: NavigationKind) -> Bool { endpoint()?.server.supports(kind) ?? false }

	// MARK: Mouse

	private func hover(_ word: Range<Int>?) {
		hoverTask?.cancel()
		guard let word, let editor, let end = endpoint(), end.server.supports(.definition) else { return }
		let rope = editor.rope, version = editor.document.version
		if let known, known.range == word, known.version == version {
			if !known.locations.isEmpty { editor.linkRange = word }
			return
		}
		hoverTask = Task { [weak self] in
			try? await Task.sleep(for: .milliseconds(50)) // the mouse passing over words asks nothing
			guard !Task.isCancelled else { return }
			let found = (try? await end.server.locations(.definition, uri: end.uri, offset: word.lowerBound, in: rope)) ?? []
			guard !Task.isCancelled, let self, let editor = self.editor, editor.document.version == version else { return }
			known = (word, version, found)
			if !found.isEmpty, editor.hoveredWord == word { editor.linkRange = word }
		}
	}

	/// False without a server that knows definitions: the click places the caret as usual.
	private func click(at offset: Int) -> Bool {
		guard let editor, let end = endpoint(), end.server.supports(.definition) else { return false }
		// The caret goes to the clicked symbol first: Back returns there.
		editor.setSelections(SelectionSet(caret: offset))
		let rope = editor.rope, version = editor.document.version, encoding = end.server.positionEncoding
		generation += 1
		let gen = generation
		let cached = known.flatMap { $0.version == version && ($0.range.contains(offset) || $0.range.upperBound == offset) ? $0.locations : nil }
		Task { [weak self] in
			var found = cached
			if found == nil { found = try? await end.server.locations(.definition, uri: end.uri, offset: offset, in: rope) }
			guard let self, gen == generation, editor.document.version == version, let found else { return }
			// On the declaration itself: its usages.
			let here = !found.isEmpty && found.allSatisfy { loc in
				loc.uri == end.uri && { $0.contains(offset) || $0.upperBound == offset }(rope.range(of: loc.range, encoding: encoding))
			}
			if here, end.server.supports(.references) {
				let usages = (try? await end.server.locations(.references, uri: end.uri, offset: offset, in: rope)) ?? []
				guard gen == generation else { return }
				await present(usages, at: offset, usagesOf: name(at: offset, in: rope))
			} else {
				await present(found, at: offset)
			}
		}
		return true
	}

	// MARK: Menu commands

	/// Navigate › Jump to Definition (⌘B), Implementation (⌥⌘B), Type Definition (⇧⌘B).
	func jump(_ kind: NavigationKind) {
		guard let editor, let end = endpoint(), end.server.supports(kind) else { return NSSound.beep() }
		let rope = editor.rope, caret = editor.caret, version = editor.document.version
		generation += 1
		let gen = generation
		Task { [weak self] in
			let found = (try? await end.server.locations(kind, uri: end.uri, offset: caret, in: rope)) ?? []
			guard let self, gen == generation, editor.document.version == version else { return }
			await present(found, at: caret)
		}
	}

	/// Navigate › Find Usages (⌥F7): the usages of the symbol at the caret in the Usages panel.
	func findUsages() {
		guard let editor, let end = endpoint(), end.server.supports(.references) else { return NSSound.beep() }
		let rope = editor.rope, caret = editor.caret, encoding = end.server.positionEncoding
		showUsages?(name(at: caret, in: rope)) {
			guard let found = try? await end.server.locations(.references, uri: end.uri, offset: caret, in: rope,
			                                                   includeDeclaration: true) else { return nil }
			return await NavigationTarget.resolve(found, encoding: encoding)
		}
	}

	// MARK: Targets

	private func name(at offset: Int, in rope: Rope) -> String {
		var range = rope.wordRange(at: offset)
		if range.count > 200 { range = range.lowerBound..<range.lowerBound }
		return rope.string(in: range)
	}

	/// None: a beep; one: the jump; several: a menu at the symbol (usages: at most 30, then
	/// the rest in the Usages panel).
	private func present(_ locations: [Location], at offset: Int, usagesOf name: String? = nil) async {
		guard let end = endpoint() else { return }
		let gen = generation
		let targets = await NavigationTarget.resolve(locations, encoding: end.server.positionEncoding)
		guard gen == generation, editor != nil else { return }
		switch targets.count {
		case 0: NSSound.beep()
		case 1: open(targets[0])
		default: showMenu(targets, at: offset, usagesOf: name)
		}
	}

	private func open(_ target: NavigationTarget) {
		let caret = target.range.lowerBound..<target.range.lowerBound
		(editor?.window?.delegate as? DocumentWindow)?.recordJump()
		if let editor, editor.document === FileDocument.document(for: target.url)?.text {
			editor.reveal(caret)
		} else {
			let project = (editor?.window?.delegate as? DocumentWindow)?.project
			(NSApp.delegate as? AppDelegate)?.open(target.url, range: caret, from: project)
		}
	}

	private static let menuLimit = 30

	private func showMenu(_ targets: [NavigationTarget], at offset: Int, usagesOf name: String?) {
		guard let editor, let window = editor.window else { return }
		let menu = NSMenu()
		let root = (window.delegate as? DocumentWindow)?.project?.url
		for target in targets.prefix(Self.menuLimit) {
			var text = target.line.text.trimmingCharacters(in: .whitespaces)
			if text.count > 80 { text = text.prefix(80) + "…" }
			let item = MenuAction(text) { [weak self] in self?.open(target) }
			let title = NSMutableAttributedString(string: text, attributes: [.font: NSFont.menuFont(ofSize: 0)])
			title.append(NSAttributedString(string: "   " + Self.place(target, root: root), attributes: [
				.font: NSFont.menuFont(ofSize: NSFont.smallSystemFontSize), .foregroundColor: NSColor.secondaryLabelColor,
			]))
			item.attributedTitle = title
			menu.addItem(item)
		}
		if let name, showUsages != nil, targets.count > Self.menuLimit {
			menu.addItem(.separator())
			menu.addItem(MenuAction(Strings.navigation.showAllUsages(count: targets.count)) { [weak self] in
				self?.showUsages?(name) { targets }
			})
		}
		let utf16 = editor.rope.utf16Offset(ofByte: offset)
		let screen = editor.firstRect(forCharacterRange: NSRange(location: utf16, length: 0), actualRange: nil)
		let rect = editor.convert(window.convertFromScreen(screen), from: nil)
		menu.popUp(positioning: nil, at: NSPoint(x: rect.minX, y: rect.maxY), in: editor)
	}

	/// "internal/store/store.go:42", relative to the project when inside it.
	static func place(_ target: NavigationTarget, root: URL?) -> String {
		path(target.url, root: root) + ":" + String(target.line.line + 1)
	}

	static func path(_ url: URL, root: URL?) -> String {
		var path = url.path
		if let root, path.hasPrefix(root.path + "/") { path.removeFirst(root.path.count + 1) }
		return path
	}
}

/// A menu item that runs a closure.
nonisolated final class MenuAction: NSMenuItem {
	private nonisolated(unsafe) let run: () -> Void

	init(_ title: String, _ run: @escaping () -> Void) {
		self.run = run
		super.init(title: title, action: #selector(perform(_:)), keyEquivalent: "")
		target = self
	}

	required init(coder: NSCoder) { fatalError("init(coder:) is not used") }

	@objc @MainActor private func perform(_ sender: Any?) { run() }
}
