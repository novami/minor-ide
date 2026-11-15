import AppKit
import EditorKit
import Highlight
import MinorCore
import TextEngine

/// One editor window (a tab of a project window): one or two panes (split), each showing
/// a file. Title, saving and the Format menu follow the focused pane.
@MainActor
final class DocumentWindow: NSObject, NSWindowDelegate, NSToolbarDelegate, NSMenuItemValidation {
	let window: EditorWindow
	/// Panes in the order of the split view; at least one.
	var panes: [EditorPane]
	let editorSplit = NSSplitView()
	let find: FindController
	private let findBar: FindBar
	var findBarView: FindBar { findBar }

	/// The folder this window belongs to; its windows are tabs of one window group.
	let project: Project?
	private var compareWindow: CompareWindow?
	private(set) var sidebar: ProjectSidebar?
	/// Split items of a project window: sidebar, right panel (an AppKit inspector item), bottom panel.
	private var panels: (side: NSSplitViewItem, inspector: NSSplitViewItem, bottom: NSSplitViewItem)?
	private var panelSplitViews: [NSSplitView] = []

	/// The first pane's editor; `splitEditor` is the second pane's.
	var editor: EditorView { panes[0].editor }
	var splitEditor: EditorView? { panes.count > 1 ? panes[1].editor : nil }
	var focusedPane: EditorPane { panes.first { $0.editor === find.editor } ?? panes[0] }
	/// The file of the focused pane.
	var document: FileDocument { focusedPane.document }
	var url: URL? { document.url }
	var format: FormatSettings { document.format }
	var mixedLineEndings: Bool { document.mixedLineEndings }
	/// Files shown in this window, each once.
	var documents: [FileDocument] {
		panes.reduce(into: []) { list, pane in if !list.contains(where: { $0 === pane.document }) { list.append(pane.document) } }
	}

	func pane(showing url: URL) -> EditorPane? {
		panes.first { $0.document.url?.standardizedFileURL == url.standardizedFileURL }
	}

	convenience init(text: String, project: Project? = nil) {
		self.init(document: FileDocument(text: text), project: project)
	}

	init(document: FileDocument, project: Project? = nil) {
		self.project = project
		window = EditorWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 800),
		                  styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
		let first = EditorPane(document: document, font: Self.editorFont)
		panes = [first]
		editorSplit.dividerStyle = .thin
		editorSplit.isVertical = true
		editorSplit.addSubview(first.view)
		find = FindController(editor: first.editor)
		findBar = FindBar(controller: find)
		findBar.isHidden = true
		trustBanner.setContentHuggingPriority(.required, for: .vertical)
		let content = NSStackView(views: [trustBanner, findBar, editorSplit, statusBar])
		content.orientation = .vertical
		content.spacing = 0
		content.alignment = .width
		content.distribution = .fill
		editorSplit.setContentHuggingPriority(.defaultLow, for: .vertical)
		// A split view has no width of its own; .width alignment alone leaves it at zero.
		editorSplit.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
		findBar.setContentHuggingPriority(.required, for: .vertical)
		statusBar.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
		if let project {
			// Sidebar and editor in a split view controller (HIG sidebar, View › Show Sidebar).
			let sidebar = ProjectSidebar(project: project)
			self.sidebar = sidebar
			let split = NSSplitViewController()
			let side = NSViewController()
			side.view = sidebar
			let main = NSViewController()
			main.view = content
			let sideItem = NSSplitViewItem(sidebarWithViewController: side)
			sideItem.minimumThickness = 180
			sideItem.canCollapse = true
			// Editor above the bottom panel (terminal).
			let center = NSSplitViewController()
			center.splitView.isVertical = false
			center.splitView.dividerStyle = .thin
			let editorItem = NSSplitViewItem(viewController: main)
			editorItem.minimumThickness = 120
			center.addSplitViewItem(editorItem)
			let bottom = NSViewController()
			bottom.view = PanelView.bottom()
			let bottomItem = NSSplitViewItem(viewController: bottom)
			bottomItem.canCollapse = true
			bottomItem.minimumThickness = 100
			bottomItem.holdingPriority = .defaultLow + 10 // the editor takes window resizes
			center.addSplitViewItem(bottomItem)
			center.splitView.autosaveName = "ProjectBottomPanel"
			// Database and server browsers on the right.
			let inspector = NSViewController()
			inspector.view = PanelView.inspector()
			let inspectorItem = NSSplitViewItem(inspectorWithViewController: inspector)
			inspectorItem.minimumThickness = 240
			inspectorItem.canCollapse = true
			split.addSplitViewItem(sideItem)
			split.addSplitViewItem(NSSplitViewItem(viewController: center))
			split.addSplitViewItem(inspectorItem)
			split.splitView.autosaveName = "ProjectSidebar"
			panels = (sideItem, inspectorItem, bottomItem)
			panelSplitViews = [split.splitView, center.splitView]
			window.contentViewController = split
			window.setContentSize(NSSize(width: 1300, height: 800))
			window.tabbingMode = .preferred
			window.tabbingIdentifier = "project:" + project.url.path
		} else {
			window.contentView = content
		}
		window.isReleasedWhenClosed = false
		super.init()
		statusBar.owner = self
		// Unified toolbar (HIG): sidebar button for projects, file name as the title, Find.
		let toolbar = NSToolbar(identifier: project == nil ? "Editor" : "ProjectEditor")
		toolbar.delegate = self
		toolbar.displayMode = .iconOnly
		toolbar.allowsUserCustomization = false
		window.toolbar = toolbar
		window.toolbarStyle = .unified
		sidebar?.onOpen = { url in (NSApp.delegate as? AppDelegate)?.open(url) }
		sidebar?.onOpenInSplit = { [weak self] url in
			guard let self else { return }
			(NSApp.delegate as? AppDelegate)?.open(url, inSplitOf: self)
		}
		sidebar?.onMoved = { from, to in (NSApp.delegate as? AppDelegate)?.filesMoved(from: from, to: to) }
		if let url = document.url { sidebar?.reveal(url) }
		observePanels()
		window.delegate = self
		configure(first)
		window.closesPane = { [weak self] in self?.closeFocusedPane() ?? false }
		NotificationCenter.default.addObserver(self, selector: #selector(documentStateChanged(_:)),
		                                       name: FileDocument.stateDidChange, object: nil)
		NotificationCenter.default.addObserver(self, selector: #selector(documentReplaced(_:)),
		                                       name: FileDocument.didReplace, object: nil)
		findBar.onClose = { [weak self] in self?.hideFindBar() }
		if ProcessInfo.processInfo.environment["MINORIDE_LATENCY"] == "1" {
			let monitor = LatencyMonitor(view: first.editor)
			monitor.onFrame = { [weak monitor] _ in
				guard let frames = monitor?.frames, frames.count % 100 == 0 else { return }
				let last = frames.suffix(100).sorted()
				print(String(format: "key to frame (last 100): p50 %.2f ms, p99 %.2f ms, max %.2f ms",
				             last[50] * 1000, last[98] * 1000, last[99] * 1000))
			}
			first.editor.latencyMonitor = monitor
		}
		first.editor.updateSize()
		updateTitle()
		project?.onTrustChange.append { [weak self] in
			self?.updateTrustBanner()
			self?.statusBar.update()
		}
		updateTrustBanner()
	}

	/// Cursor position, language and the file's format under the editor.
	let statusBar = StatusBar()

	// MARK: Restricted Mode (D18)

	/// Bar in every tab of a project that is not trusted; hiding it lasts for the tab.
	private let trustBanner = DiskBanner(symbol: "shield.lefthalf.filled", tint: .secondaryLabelColor, returnKey: false)
	private var trustBannerDismissed = false

	private func updateTrustBanner() {
		guard let project, !project.isTrusted, !trustBannerDismissed else {
			trustBanner.isHidden = true
			return
		}
		trustBanner.show(L("Restricted Mode: MinorIDE doesn’t run Git, tools or commands from this project."), [
			(L("Trust Project…"), { [weak self] in self?.toggleProjectTrust(nil) }, false),
			(L("Learn More"), { Self.openHelp(anchor: "restricted-mode") }, false),
			(L("Hide"), { [weak self] in self?.trustBannerDismissed = true }, true),
		])
	}

	static func openHelp(anchor: String) {
		guard let book = Bundle.main.object(forInfoDictionaryKey: "CFBundleHelpBookName") as? String else { return }
		NSHelpManager.shared.openHelpAnchor(anchor, inBook: book)
	}

	/// File › Trust Project… asks first; Restrict Project applies at once (the safe direction).
	@objc func toggleProjectTrust(_ sender: Any?) {
		guard let project else { return }
		if project.isTrusted {
			setTrust(false, project)
			return
		}
		let alert = NSAlert()
		alert.messageText = L("Trust the project “%@”?", project.name)
		alert.informativeText = L("A trusted project can run code when MinorIDE uses Git, language servers, tools, run configurations or the debugger on it. Trust only projects from authors you trust.")
		alert.addButton(withTitle: L("Trust"))
		alert.addButton(withTitle: L("Cancel"))
		alert.beginSheetModal(for: window) { [weak self] response in
			guard response == .alertFirstButtonReturn else { return }
			self?.setTrust(true, project)
		}
	}

	private func setTrust(_ trusted: Bool, _ project: Project) {
		do {
			try project.setTrusted(trusted)
		} catch {
			NSAlert(error: error).beginSheetModal(for: window)
		}
	}

	/// Another document was saved over this window's file: its panes show that document.
	@objc private func documentReplaced(_ notification: Notification) {
		guard let old = notification.object as? FileDocument,
		      let new = notification.userInfo?[FileDocument.replacementKey] as? FileDocument else { return }
		for pane in panes where pane.document === old { replacePane(pane, with: new) }
	}

	/// Selects the focused pane's file in the project tree.
	func revealInSidebar() {
		if let url { sidebar?.reveal(url) }
	}

	static var editorFont: NSFont { EditorView.editorFont }

	/// Title, edited dot and disk bars follow the files of the panes.
	@objc private func documentStateChanged(_ notification: Notification) {
		guard let doc = notification.object as? FileDocument, panes.contains(where: { $0.document === doc }) else { return }
		for pane in panes where pane.document === doc { updateBanner(pane) }
		updateTitle()
	}

	private var placed = false

	/// Brings the window to front; the first time it is centred, or cascaded from `after`
	/// like new document windows in standard Mac apps.
	func show(after previous: NSWindow? = nil) {
		if !placed {
			if let previous {
				window.setFrameTopLeftPoint(previous.cascadeTopLeft(from: NSPoint(x: previous.frame.minX, y: previous.frame.maxY)))
			} else {
				window.center()
			}
			placed = true
		}
		window.makeKeyAndOrderFront(nil)
		window.makeFirstResponder(find.editor)
	}

	/// Moves the focus to the pane showing `url`.
	func focus(_ url: URL) {
		if let pane = pane(showing: url) { window.makeFirstResponder(pane.editor) }
	}

	/// Shows a window just added as a tab (the tab group keeps its place, no centring).
	func showAsTab() {
		placed = true
		window.makeKeyAndOrderFront(nil)
		window.makeFirstResponder(editor)
	}

	/// Right-click menu of the editor (AppKit adds Services for the selection).
	static func contextMenu() -> NSMenu {
		let menu = NSMenu()
		menu.item(L("Cut"), #selector(NSText.cut(_:)))
		menu.item(L("Copy"), #selector(NSText.copy(_:)))
		menu.item(L("Paste"), #selector(NSText.paste(_:)))
		menu.addItem(.separator())
		menu.item(L("Comment Selection"), #selector(EditorView.toggleComment(_:)))
		menu.item(L("Find…"), #selector(DocumentWindow.showFind(_:)))
		menu.addItem(.separator())
		let speech = menu.item(L("Speech"), nil)
		speech.submenu = NSMenu(title: L("Speech"))
		speech.submenu!.item(L("Start Speaking"), #selector(EditorView.startSpeaking(_:)))
		speech.submenu!.item(L("Stop Speaking"), #selector(EditorView.stopSpeaking(_:)))
		return menu
	}

	// MARK: Changes on disk

	func windowDidBecomeKey(_ notification: Notification) {
		applyPanels()
		revealInSidebar()
		documents.forEach { $0.checkDisk() }
	}

	/// Shows the pane's bar when its file changed or vanished on disk while it has unsaved changes.
	func updateBanner(_ pane: EditorPane) {
		let doc = pane.document
		guard doc.diskNotice != pane.shownNotice else { return }
		pane.shownNotice = doc.diskNotice
		switch doc.diskNotice {
		case nil: pane.banner.isHidden = true
		case .deleted:
			pane.banner.show(L("The file was deleted from disk. Saving creates it again."), [(L("OK"), { doc.dismissDiskNotice() }, true)])
		case .changed:
			pane.banner.show(L("The file changed on disk."), [
				(L("Reload"), { doc.reload() }, true),
				(L("Keep Mine"), { doc.keepMine() }, true),
				(L("Compare"), { [weak self] in self?.compareWithDisk(doc) }, false),
			])
		}
	}

	// MARK: Panels

	/// Which panels are hidden is shared by all project windows, so switching tabs keeps the layout.
	private static let panelKeys = (side: "PanelSidebarHidden", inspector: "PanelInspectorHidden", bottom: "PanelBottomHidden")

	private func observePanels() {
		guard let panels else { return }
		applyPanels()
		// Split views post this after collapsing or expanding an item.
		for view in panelSplitViews {
			NotificationCenter.default.addObserver(self, selector: #selector(panelsResized(_:)),
			                                       name: NSSplitView.didResizeSubviewsNotification, object: view)
		}
	}

	@objc private func panelsResized(_ notification: Notification) {
		guard let panels, window.isKeyWindow else { return }
		let d = UserDefaults.standard
		d.set(panels.side.isCollapsed, forKey: Self.panelKeys.side)
		d.set(panels.inspector.isCollapsed, forKey: Self.panelKeys.inspector)
		d.set(panels.bottom.isCollapsed, forKey: Self.panelKeys.bottom)
	}

	private func applyPanels() {
		guard let panels else { return }
		let d = UserDefaults.standard
		for (item, key) in [(panels.side, Self.panelKeys.side), (panels.inspector, Self.panelKeys.inspector), (panels.bottom, Self.panelKeys.bottom)] {
			let hidden = d.bool(forKey: key)
			if item.isCollapsed != hidden { item.isCollapsed = hidden }
		}
	}

	@objc func toggleRightPanel(_ sender: Any?) {
		guard let item = panels?.inspector else { return }
		item.animator().isCollapsed.toggle()
	}

	@objc func toggleBottomPanel(_ sender: Any?) {
		guard let item = panels?.bottom else { return }
		item.animator().isCollapsed.toggle()
	}

	func validateMenuItem(_ item: NSMenuItem) -> Bool {
		switch item.action {
		case #selector(toggleBottomPanel(_:)):
			guard let bottom = panels?.bottom else { return false }
			item.title = bottom.isCollapsed ? L("Show Bottom Panel") : L("Hide Bottom Panel")
		case #selector(closeEditorSplit(_:)):
			return splitEditor != nil
		case #selector(showLocalHistory(_:)):
			return document.url != nil && FileDocument.history != nil
		case #selector(toggleProjectTrust(_:)):
			guard let project else { return false }
			item.title = project.isTrusted ? L("Restrict Project") : L("Trust Project…")
		case #selector(toggleRightPanel(_:)):
			guard let right = panels?.inspector else { return false }
			item.title = right.isCollapsed ? L("Show Right Panel") : L("Hide Right Panel")
		default: break
		}
		return true
	}

	private var historyWindow: LocalHistoryWindow?

	/// File › Local History…: saved versions of the focused file.
	@objc func showLocalHistory(_ sender: Any?) {
		if let historyWindow, historyWindow.document === document { return historyWindow.window.makeKeyAndOrderFront(nil) }
		historyWindow?.window.close()
		let history = LocalHistoryWindow(document: document)
		history.onClose = { [weak self] in self?.historyWindow = nil }
		historyWindow = history
	}

	/// Diff of the file on disk against the editor's text, in its own window.
	func compareWithDisk(_ doc: FileDocument) {
		guard let url = doc.url, let disk = doc.diskText() else { return }
		let name = url.lastPathComponent
		let compare = CompareWindow(title: name, old: disk, new: doc.text.rope.string,
		                            oldLabel: L("%@ (on disk)", name), newLabel: L("%@ (in the editor)", name))
		compare.onClose = { [weak self] in self?.compareWindow = nil }
		compareWindow = compare
	}

	// MARK: Format changes (Format menu, the focused pane's file)

	func setLineEnding(_ eol: LineEnding) { document.setLineEnding(eol) }

	func setIndent(style: IndentStyle, size: Int) {
		var format = document.format
		format.indentStyle = style
		format.indentSize = size
		document.formatChosenByUser = true
		document.format = format
	}

	func setTabWidth(_ width: Int) {
		document.formatChosenByUser = true
		document.format.tabWidth = width
	}

	// MARK: Find (Edit › Find; the window delegate is in the responder chain of the editor and the bar)

	func showFindBar(replace: Bool) {
		if find.query.text.isEmpty, let text = FindPasteboard.read() { find.query.text = text }
		let opening = findBar.isHidden
		findBar.isHidden = false
		findBar.showsReplace = replace
		find.showsHighlights = true
		if opening { find.refresh() }
		findBar.syncFromController()
		window.makeFirstResponder(findBar.findField)
		findBar.findField.currentEditor()?.selectAll(nil)
	}

	func hideFindBar() {
		findBar.isHidden = true
		find.showsHighlights = false
		window.makeFirstResponder(find.editor)
	}

	@objc func showFind(_ sender: Any?) { showFindBar(replace: false) }
	@objc func showFindAndReplace(_ sender: Any?) { showFindBar(replace: true) }
	@objc func findNextMatch(_ sender: Any?) { findAgain(forward: true) }
	@objc func findPreviousMatch(_ sender: Any?) { findAgain(forward: false) }

	private func findAgain(forward: Bool) {
		if let text = FindPasteboard.read(), findBar.isHidden, text != find.query.text {
			find.query.text = text // another app changed the shared query
		}
		guard !find.query.text.isEmpty else { return showFindBar(replace: false) }
		if find.matches.isEmpty && find.error == nil { find.refresh() }
		Task { await find.findNext(forward: forward) }
	}

	@objc func useSelectionForFind(_ sender: Any?) {
		find.useSelection()
		FindPasteboard.write(find.query.text)
		findBar.syncFromController()
	}

	@objc func useSelectionForReplace(_ sender: Any?) {
		let s = find.editor.selections.primary
		guard !s.isEmpty else { return }
		find.replacement = find.editor.rope.string(in: s.range)
		findBar.syncFromController()
	}

	// MARK: Saving

	@discardableResult
	func save() -> Bool { save(document) }

	@discardableResult
	func saveAs() -> Bool { saveAs(document) }

	private func save(_ doc: FileDocument) -> Bool {
		guard let url = doc.url else { return saveAs(doc) }
		return write(doc, to: url)
	}

	private func saveAs(_ doc: FileDocument) -> Bool {
		let panel = NSSavePanel()
		panel.nameFieldStringValue = doc.url?.lastPathComponent ?? L("Untitled")
		if let dir = doc.url?.deletingLastPathComponent() { panel.directoryURL = dir }
		guard panel.runModal() == .OK, let chosen = panel.url else { return false }
		// One model per file: the open document of that path gives way to this one.
		if let other = FileDocument.document(for: chosen), other !== doc, other.isEdited {
			let alert = NSAlert()
			alert.messageText = L("“%@” is open with unsaved changes. Do you want to replace it?", chosen.lastPathComponent)
			alert.informativeText = L("Its unsaved changes will be lost.")
			alert.addButton(withTitle: L("Replace"))
			alert.addButton(withTitle: L("Cancel"))
			guard alert.runModal() == .alertFirstButtonReturn else { return false }
		}
		return write(doc, to: chosen)
	}

	private func write(_ doc: FileDocument, to url: URL) -> Bool {
		if let char = TextFile.firstUnencodable(doc.text.rope.string, charset: doc.format.charset) {
			askToSaveAsUTF8(doc, to: url, char: char)
			return false // the sheet saves (or not) when answered
		}
		do {
			try doc.write(to: url)
			NSDocumentController.shared.noteNewRecentDocumentURL(url)
			return true
		} catch {
			NSAlert(error: error).beginSheetModal(for: window)
			return false
		}
	}

	/// The text has characters the file's charset cannot store: saving would turn them into
	/// "?", so offer UTF-8 instead.
	private func askToSaveAsUTF8(_ doc: FileDocument, to url: URL, char: Character) {
		let alert = NSAlert()
		let charset = doc.format.charset.rawValue.uppercased()
		alert.messageText = L("“%@” contains characters that %@ can’t store, such as “%@”.", url.lastPathComponent, charset, String(char))
		alert.informativeText = L("Saving in %@ would replace them with question marks. You can save the file in UTF-8 instead, or remove those characters.", charset)
		alert.addButton(withTitle: L("Save as UTF-8"))
		alert.addButton(withTitle: L("Cancel"))
		alert.beginSheetModal(for: window) { [weak self] response in
			MainActor.assumeIsolated {
				guard response == .alertFirstButtonReturn, let self else { return }
				doc.format.charset = .utf8
				_ = self.write(doc, to: url)
			}
		}
	}

	/// Title and tab follow the focused pane's file; its format is in the status bar.
	func updateTitle() {
		let doc = document
		let name = doc.url?.lastPathComponent ?? L("Untitled")
		window.title = name
		statusBar.update()
		window.representedURL = doc.url
		window.tab.title = project.map { doc.url == nil ? $0.name : name } ?? name
		// The dot in the close button: any file of the window has unsaved changes.
		let edited = panes.contains { $0.document.isEdited }
		if window.isDocumentEdited != edited { window.isDocumentEdited = edited }
	}

	// MARK: Closing

	/// An edited file asks before it closes with its last editor.
	func needsConfirm(_ doc: FileDocument, closing editors: [EditorView]) -> Bool {
		doc.isEdited && doc.text.views.allSatisfy { view in editors.contains { $0 === view } }
	}

	/// HIG save dialog as a sheet: Save (default) / Cancel / Don't Save. Completion gets true
	/// when the file may close.
	func confirmSave(_ doc: FileDocument, _ completion: @escaping (Bool) -> Void) {
		if let url = doc.url { focus(url) }
		let alert = NSAlert()
		alert.messageText = L("Do you want to save the changes made to the document “%@”?", doc.url?.lastPathComponent ?? L("Untitled"))
		alert.informativeText = L("Your changes will be lost if you don’t save them.")
		alert.addButton(withTitle: L("Save"))
		alert.addButton(withTitle: L("Cancel"))
		let dontSave = alert.addButton(withTitle: L("Don’t Save"))
		dontSave.keyEquivalent = "d"
		dontSave.keyEquivalentModifierMask = .command
		alert.beginSheetModal(for: window) { [weak self] response in
			MainActor.assumeIsolated {
				guard let self else { return completion(false) }
				switch response {
				case .alertFirstButtonReturn: completion(self.save(doc))
				case .alertThirdButtonReturn:
					doc.discardChanges()
					completion(true)
				default: completion(false)
				}
			}
		}
	}

	/// Asks about each edited file no other window shows; true when the window may close.
	func confirmClose(_ completion: @escaping (Bool) -> Void) {
		let editors = panes.map(\.editor)
		confirmEach(documents.filter { needsConfirm($0, closing: editors) }[...], completion)
	}

	/// Asks about every edited file of the window (quitting).
	func confirmEdited(_ completion: @escaping (Bool) -> Void) {
		confirmEach(documents.filter(\.isEdited)[...], completion)
	}

	private func confirmEach(_ docs: ArraySlice<FileDocument>, _ completion: @escaping (Bool) -> Void) {
		guard let doc = docs.first else { return completion(true) }
		confirmSave(doc) { [weak self] ok in
			guard ok, let self else { return completion(false) }
			confirmEach(docs.dropFirst(), completion)
		}
	}

	func windowShouldClose(_ sender: NSWindow) -> Bool {
		let editors = panes.map(\.editor)
		guard documents.contains(where: { needsConfirm($0, closing: editors) }) else { return true }
		confirmClose { [weak self] ok in
			if ok { self?.window.close() }
		}
		return false
	}

	/// Editors of a closed window stop following their files at once (the file may stay open elsewhere).
	func windowWillClose(_ notification: Notification) {
		for pane in panes { pane.document.text.detach(pane.editor) }
	}
}

// MARK: Toolbar

extension DocumentWindow {
	static let findItem = NSToolbarItem.Identifier("find")
	static let bottomPanelItem = NSToolbarItem.Identifier("bottomPanel")
	static let rightPanelItem = NSToolbarItem.Identifier("rightPanel")

	func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
		project == nil ? [.flexibleSpace, Self.findItem]
			: [.toggleSidebar, .sidebarTrackingSeparator, .flexibleSpace, Self.findItem, Self.bottomPanelItem,
			   .inspectorTrackingSeparator, .flexibleSpace, Self.rightPanelItem]
	}

	func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
		toolbarDefaultItemIdentifiers(toolbar)
	}

	func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
		if id == Self.rightPanelItem {
			let item = NSToolbarItem(itemIdentifier: id)
			item.label = L("Right Panel")
			item.toolTip = L("Show or hide the right panel")
			item.image = NSImage(systemSymbolName: "sidebar.right", accessibilityDescription: L("Right Panel"))
			item.action = #selector(toggleRightPanel(_:))
			item.target = self
			item.isBordered = true
			return item
		}
		if id == Self.bottomPanelItem {
			let item = NSToolbarItem(itemIdentifier: id)
			item.label = L("Bottom Panel")
			item.toolTip = L("Show or hide the bottom panel")
			item.image = NSImage(systemSymbolName: "rectangle.bottomthird.inset.filled", accessibilityDescription: L("Bottom Panel"))
			item.action = #selector(toggleBottomPanel(_:))
			item.target = self
			item.isBordered = true
			return item
		}
		guard id == Self.findItem else { return nil }
		let item = NSToolbarItem(itemIdentifier: id)
		item.label = L("Find")
		item.toolTip = L("Find")
		item.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: L("Find"))
		item.action = #selector(showFind(_:))
		item.target = self
		item.isBordered = true
		return item
	}
}
