import AppKit

/// Window whose File › Close (⌘W) closes the focused split pane before the window.
final class EditorWindow: NSWindow {
	/// Returns true when it closed a pane instead of the window.
	var closesPane: (() -> Bool)?

	override func performClose(_ sender: Any?) {
		// The close button closes the window; only the menu item (⌘W) closes a pane.
		if sender is NSMenuItem, closesPane?() == true { return }
		super.performClose(sender)
	}

	/// Side buttons of a mouse: Back (3) and Forward (4) wherever the pointer is in the window.
	override func otherMouseDown(with event: NSEvent) {
		switch event.buttonNumber {
		case 3: NSApp.sendAction(#selector(DocumentWindow.navigateBack(_:)), to: nil, from: self)
		case 4: NSApp.sendAction(#selector(DocumentWindow.navigateForward(_:)), to: nil, from: self)
		default: super.otherMouseDown(with: event)
		}
	}
}

/// One part of a window's editor: a file's editor with the bar for changes on disk above it.
@MainActor
final class EditorPane {
	let document: FileDocument
	let editor: EditorView
	let banner = DiskBanner()
	/// Completion from the project's language server (nil outside a project).
	var completion: CompletionController?
	var signatureHelp: SignatureHelpController?
	var hover: HoverController?
	/// Jumps to definitions and usages (nil outside a project).
	var navigation: NavigationController?
	var codeActions: CodeActionController?
	/// Notice the banner shows, so repeated state changes do not rebuild it.
	var shownNotice: FileDocument.DiskNotice?
	let view: NSStackView

	init(document: FileDocument, font: NSFont) {
		self.document = document
		editor = EditorView(document: document.text, font: font)
		let scroll = DocumentWindow.makeScrollView(for: editor)
		scroll.setContentHuggingPriority(.defaultLow, for: .vertical)
		banner.setContentHuggingPriority(.required, for: .vertical)
		view = NSStackView(views: [banner, scroll])
		view.orientation = .vertical
		view.spacing = 0
		view.alignment = .width
		view.distribution = .fill
	}
}

/// The editor of a window split in two panes (View › Split Editor); each pane shows a file,
/// the same one or another.
extension DocumentWindow {
	static func makeScrollView(for editor: EditorView) -> NSScrollView {
		let scroll = NSScrollView()
		scroll.hasVerticalScroller = true
		scroll.hasHorizontalScroller = true // lines that do not wrap
		scroll.autohidesScrollers = true // also with "always show scroll bars"
		scroll.backgroundColor = .textBackgroundColor // below the last line
		scroll.wantsLayer = true // clip view, gutter and editor draw into layers
		editor.autoresizingMask = [.width]
		scroll.documentView = editor
		GutterView.install(for: editor)
		StickyLinesView.install(for: editor)
		DiagnosticStripView.install(for: editor)
		return scroll
	}

	@objc func splitEditorSideBySide(_ sender: Any?) { split(vertical: true) }
	@objc func splitEditorTopAndBottom(_ sender: Any?) { split(vertical: false) }
	@objc func closeEditorSplit(_ sender: Any?) { _ = closeFocusedPane() }

	/// Opens the second pane on the focused pane's file and position, or changes the direction of an open split.
	func split(vertical: Bool) {
		editorSplit.isVertical = vertical
		guard panes.count == 1 else { return centerDivider() }
		let second = addPane(document)
		second.editor.adoptViewState(of: find.editor)
		window.makeFirstResponder(second.editor)
	}

	/// Shows `doc` in the other pane (⌥-click in the project tree), splitting side by side
	/// when the editor is not split yet.
	func openInSplit(_ doc: FileDocument) {
		guard panes.count > 1 else {
			let pane = addPane(doc)
			if doc === panes[0].document { pane.editor.adoptViewState(of: panes[0].editor) }
			window.makeFirstResponder(pane.editor)
			return
		}
		let focused = focusedPane
		guard let other = panes.first(where: { $0 !== focused }) else { return }
		if other.document === doc { return showPane(other) }
		let replace = { [weak self] in
			guard let self, let pane = replacePane(other, with: doc) else { return }
			showPane(pane)
		}
		if needsConfirm(other.document, closing: [other.editor]) {
			confirmSave(other.document) { ok in if ok { replace() } }
		} else {
			replace()
		}
	}

	/// Puts a new pane for `doc` where `old` was.
	@discardableResult
	func replacePane(_ old: EditorPane, with doc: FileDocument) -> EditorPane? {
		guard let index = panes.firstIndex(where: { $0 === old }) else { return nil }
		let focused = old === focusedPane
		let pane = makePane(doc)
		pane.view.frame = old.view.frame
		editorSplit.replaceSubview(old.view, with: pane.view)
		old.document.text.detach(old.editor)
		panes[index] = pane
		if focused {
			find.editor = pane.editor
			if window.firstResponder === old.editor { window.makeFirstResponder(pane.editor) }
		}
		updateTitle()
		return pane
	}

	private func showPane(_ pane: EditorPane) {
		window.makeFirstResponder(pane.editor)
		if let url = pane.document.url { sidebar?.reveal(url) }
	}

	private func makePane(_ doc: FileDocument) -> EditorPane {
		let pane = EditorPane(document: doc, font: editor.font)
		configure(pane)
		return pane
	}

	/// Adds the second pane with the divider in the middle.
	private func addPane(_ doc: FileDocument) -> EditorPane {
		let pane = makePane(doc)
		editorSplit.addSubview(pane.view)
		panes.append(pane)
		centerDivider()
		return pane
	}

	private func centerDivider() {
		editorSplit.layoutSubtreeIfNeeded()
		let total = editorSplit.isVertical ? editorSplit.bounds.width : editorSplit.bounds.height
		editorSplit.setPosition(((total - editorSplit.dividerThickness) / 2).rounded(), ofDividerAt: 0)
		editorSplit.layoutSubtreeIfNeeded()
	}

	/// Closes the focused pane (asking to save a file no other editor shows); false without a split.
	func closeFocusedPane() -> Bool {
		guard panes.count > 1 else { return false }
		let pane = focusedPane
		let close = { [weak self] in
			guard let self, panes.count > 1, panes.contains(where: { $0 === pane }) else { return }
			pane.view.removeFromSuperview()
			pane.document.text.detach(pane.editor)
			panes.removeAll { $0 === pane }
			project?.languageServers.scheduleSync()
			find.editor = panes[0].editor
			window.makeFirstResponder(panes[0].editor)
			updateTitle()
		}
		if needsConfirm(pane.document, closing: [pane.editor]) {
			confirmSave(pane.document) { ok in if ok { close() } }
		} else {
			close()
		}
		return true
	}

	/// Settings shared by all panes.
	func configure(_ pane: EditorPane) {
		let editor = pane.editor
		project?.loadGitBase(pane.document)
		project?.languageServers.scheduleSync()
		editor.setAccessibilityLabel(Strings.split.editor)
		editor.contextMenuProvider = { DocumentWindow.contextMenu(for: $0) }
		if let services = project?.languageServers {
			let completion = CompletionController(editor: editor) { [weak services, weak doc = pane.document] in
				guard let services, let doc else { return nil }
				return services.endpoint(for: doc)
			}
			pane.completion = completion
			let signatureHelp = SignatureHelpController(editor: editor) { [weak services, weak doc = pane.document] in
				guard let services, let doc else { return nil }
				return services.endpoint(for: doc)
			}
			pane.signatureHelp = signatureHelp
			let hover = HoverController(editor: editor) { [weak services, weak doc = pane.document] in
				guard let services, let doc else { return nil }
				return services.endpoint(for: doc)
			}
			pane.hover = hover
			editor.onDiagnosticActivated = { [weak hover] in hover?.showProblems(at: $0) }
			editor.commandInterceptor = { [weak completion, weak signatureHelp, weak hover] selector in
				completion?.handle(selector) == true || signatureHelp?.handle(selector) == true || hover?.handle(selector) == true
			}
			editor.onTypedText = { [weak completion, weak signatureHelp] in
				completion?.typed($0)
				signatureHelp?.typed($0)
			}
			editor.onWillTypeText = { [weak completion] in completion?.willType($0) }
			let navigation = NavigationController(editor: editor) { [weak services, weak doc = pane.document] in
				guard let services, let doc else { return nil }
				return services.endpoint(for: doc)
			}
			navigation.showUsages = { [weak self] name, search in self?.showUsages(name, search) }
			pane.navigation = navigation
			pane.codeActions = CodeActionController(editor: editor) { [weak services, weak doc = pane.document] in
				guard let services, let doc else { return nil }
				return services.endpoint(for: doc)
			}
		}
		let completion = pane.completion, signatureHelp = pane.signatureHelp, hover = pane.hover
		editor.onFocus = { [weak self] focused in
			guard let self else { return }
			for other in panes where other.editor !== focused {
				other.completion?.close()
				other.signatureHelp?.close()
				other.hover?.close()
			}
			find.editor = focused
			updateTitle()
			revealInSidebar()
			if let url { project?.noteOpened(url) }
		}
		// Matches follow the text of the focused pane's file, whichever editor changed it.
		editor.onTextChange = { [weak self, weak editor, weak completion, weak signatureHelp, weak hover] in
			completion?.textChanged()
			signatureHelp?.textOrCaretsChanged()
			hover?.textOrCaretsChanged()
			guard let self, editor === find.editor else { return }
			if findBarView.isHidden { find.invalidate() } else { find.refresh(delay: .milliseconds(100)) }
		}
		editor.onCaretsChange = { [weak self, weak editor, weak completion, weak signatureHelp, weak hover] in
			completion?.caretsChanged()
			signatureHelp?.textOrCaretsChanged()
			hover?.textOrCaretsChanged()
			guard let self, editor === find.editor else { return }
			statusBar.setNeedsUpdate()
		}
		updateBanner(pane)
	}
}
