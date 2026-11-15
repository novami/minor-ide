import AppKit
import EditorKit
import Highlight
import MinorCore
import TextEngine

/// One editor window bound to a file (or untitled). Holds what is needed to save the file
/// back in its own conventions: line ending, charset and the lines as loaded.
@MainActor
final class DocumentWindow: NSObject, NSWindowDelegate, NSToolbarDelegate, NSMenuItemValidation {
	let window: NSWindow
	let editor: EditorView
	private(set) var url: URL?
	private(set) var format: FormatSettings
	private(set) var resolved: ResolvedFormat?
	private var originalLines: Set<Substring> = []
	private(set) var mixedLineEndings = false
	let find: FindController
	private let findBar: FindBar
	var findBarView: FindBar { findBar }

	/// The folder this window belongs to; its windows are tabs of one window group.
	let project: Project?
	private let diskBanner = DiskBanner()
	/// Modification date and size of the file as last loaded or saved.
	private var diskStamp: FileStamp?
	private var compareWindow: CompareWindow?
	private(set) var sidebar: ProjectSidebar?
	/// Split items of a project window: sidebar, inspector (right), bottom panel.
	private var panels: (side: NSSplitViewItem, inspector: NSSplitViewItem, bottom: NSSplitViewItem)?
	private var panelSplitViews: [NSSplitView] = []

	init(text: String, url: URL?, format: FormatSettings, project: Project? = nil) {
		self.url = url
		self.format = format
		self.project = project
		window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 800),
		                  styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
		let scroll = NSScrollView(frame: window.contentView!.bounds)
		scroll.autoresizingMask = [.width, .height]
		scroll.hasVerticalScroller = true
		scroll.backgroundColor = .textBackgroundColor // below the last line
		scroll.wantsLayer = true // clip view, gutter and editor draw into layers
		let size = ProcessInfo.processInfo.environment["MINORIDE_FONT_SIZE"].flatMap(Double.init) ?? 13
		editor = EditorView(text: text, font: .monospacedSystemFont(ofSize: size, weight: .regular))
		editor.autoresizingMask = [.width]
		editor.format = format
		editor.setAccessibilityLabel(L("Editor"))
		scroll.documentView = editor
		GutterView.install(for: editor)
		find = FindController(editor: editor)
		findBar = FindBar(controller: find)
		findBar.isHidden = true
		let content = NSStackView(views: [diskBanner, findBar, scroll])
		content.orientation = .vertical
		content.spacing = 0
		content.alignment = .width
		content.distribution = .fill
		scroll.setContentHuggingPriority(.defaultLow, for: .vertical)
		findBar.setContentHuggingPriority(.required, for: .vertical)
		diskBanner.setContentHuggingPriority(.required, for: .vertical)
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
		// Unified toolbar (HIG): sidebar button for projects, file name with its format as
		// the subtitle, Find.
		let toolbar = NSToolbar(identifier: project == nil ? "Editor" : "ProjectEditor")
		toolbar.delegate = self
		toolbar.displayMode = .iconOnly
		toolbar.allowsUserCustomization = false
		window.toolbar = toolbar
		window.toolbarStyle = .unified
		sidebar?.onOpen = { url in (NSApp.delegate as? AppDelegate)?.open(url) }
		sidebar?.onMoved = { from, to in (NSApp.delegate as? AppDelegate)?.filesMoved(from: from, to: to) }
		if let url { sidebar?.reveal(url) }
		observePanels()
		window.delegate = self
		editor.contextMenuProvider = { _ in DocumentWindow.contextMenu() }
		editor.onChange = { [weak self] in
			guard let self else { return }
			markEdited()
			if findBar.isHidden { find.invalidate() } else { find.refresh(delay: .milliseconds(100)) }
		}
		findBar.onClose = { [weak self] in self?.hideFindBar() }
		if ProcessInfo.processInfo.environment["MINORIDE_LATENCY"] == "1" {
			let monitor = LatencyMonitor(view: editor)
			monitor.onFrame = { [weak monitor] _ in
				guard let frames = monitor?.frames, frames.count % 100 == 0 else { return }
				let last = frames.suffix(100).sorted()
				print(String(format: "key to frame (last 100): p50 %.2f ms, p99 %.2f ms, max %.2f ms",
				             last[50] * 1000, last[98] * 1000, last[99] * 1000))
			}
			editor.latencyMonitor = monitor
		}
		editor.updateSize()
		updateTitle()
	}

	/// Opens a file: decodes it, keeps its line endings, and resolves indentation from
	/// language defaults, user and project settings, .editorconfig and the file itself.
	static func open(_ url: URL, project: Project? = nil) throws -> DocumentWindow {
		let data = try Data(contentsOf: url)
		let loaded = TextFile.load(data)
		let resolved = Self.resolve(path: url.path, detected: loaded.detected)
		var format = resolved.settings
		format.charset = loaded.charset
		let doc = DocumentWindow(text: loaded.text, url: url, format: format, project: project)
		// Large and minified files open without colouring (plan: simplified mode).
		doc.editor.language = TextFile.needsSimplifiedMode(data) ? nil : Languages.language(forPath: url.path)
		doc.resolved = resolved
		doc.originalLines = loaded.originalLines
		doc.diskStamp = FileStamp(url)
		doc.mixedLineEndings = loaded.detected.mixedLineEndings
		doc.updateTitle()
		return doc
	}

	static func resolve(path: String, detected: DetectedFormat?) -> ResolvedFormat {
		let project = projectRoot(for: path).flatMap {
			SettingsFile.load(URL(fileURLWithPath: $0).appendingPathComponent(".minoride/settings.json"))
		}
		return FormatResolver.resolve(path: path, user: SettingsFile.load(SettingsFile.userURL), project: project,
		                              editorConfig: EditorConfig.properties(forFile: path), detected: detected)
	}

	/// Nearest parent with .git, composer.json or go.mod.
	static func projectRoot(for path: String) -> String? {
		var dir = (path as NSString).deletingLastPathComponent
		let fm = FileManager.default
		while dir != "/" && !dir.isEmpty {
			for marker in [".git", "composer.json", "go.mod", ".minoride"] where fm.fileExists(atPath: dir + "/" + marker) {
				return dir
			}
			dir = (dir as NSString).deletingLastPathComponent
		}
		return nil
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
		window.makeFirstResponder(editor)
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

	/// The file was renamed or its folder moved: follow it without touching the text.
	func fileMoved(to newURL: URL) {
		url = newURL
		diskStamp = FileStamp(newURL)
		updateTitle()
	}

	// MARK: Changes on disk

	func windowDidBecomeKey(_ notification: Notification) {
		applyPanels()
		checkDisk()
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

	@objc func toggleBottomPanel(_ sender: Any?) {
		guard let item = panels?.bottom else { return }
		item.animator().isCollapsed.toggle()
	}

	func validateMenuItem(_ item: NSMenuItem) -> Bool {
		guard item.action == #selector(toggleBottomPanel(_:)) else { return true }
		guard let bottom = panels?.bottom else { return false }
		item.title = bottom.isCollapsed ? L("Show Bottom Panel") : L("Hide Bottom Panel")
		return true
	}

	/// Compares the file with the version loaded or saved: unchanged windows reload quietly
	/// (keeping the caret and scroll position), edited ones get a bar to choose.
	func checkDisk() {
		guard let url else { return }
		guard let now = FileStamp(url) else {
			guard diskStamp != nil else { return }
			diskStamp = nil
			markEdited() // saving recreates the file
			diskBanner.show(L("The file was deleted from disk. Saving creates it again."), [(L("OK"), {}, true)])
			return
		}
		guard now != diskStamp else { return }
		if !window.isDocumentEdited {
			reload()
		} else {
			diskBanner.show(L("The file changed on disk."), [
				(L("Reload"), { [weak self] in self?.reload() }, true),
				(L("Keep Mine"), { [weak self] in self?.diskStamp = now }, true),
				(L("Compare"), { [weak self] in self?.compareWithDisk() }, false),
			])
		}
	}

	/// Diff of the file on disk against the editor's text, in its own window.
	func compareWithDisk() {
		guard let url, let data = try? Data(contentsOf: url) else { return }
		let disk = TextFile.load(data, fallback: format.charset).text
		let name = url.lastPathComponent
		let compare = CompareWindow(title: name, old: disk, new: editor.rope.string,
		                            oldLabel: L("%@ (on disk)", name), newLabel: L("%@ (in the editor)", name))
		compare.onClose = { [weak self] in self?.compareWindow = nil }
		compareWindow = compare
	}

	/// Replaces the text with the file on disk as one undoable step.
	func reload() {
		guard let url, let data = try? Data(contentsOf: url) else { return }
		let loaded = TextFile.load(data, fallback: format.charset)
		let selections = editor.selections
		let origin = editor.visibleRect.origin
		if loaded.text != editor.rope.string {
			editor.replace([(0..<editor.rope.byteCount, loaded.text)])
			let end = editor.rope.byteCount
			editor.setSelections(selections.map { s in
				Selection(anchor: editor.rope.scalarBoundary(atOrBefore: min(s.anchor, end)),
				          head: editor.rope.scalarBoundary(atOrBefore: min(s.head, end)))
			})
			editor.scroll(origin)
		}
		originalLines = loaded.originalLines
		mixedLineEndings = loaded.detected.mixedLineEndings
		diskStamp = FileStamp(url)
		diskBanner.isHidden = true
		window.isDocumentEdited = false
		editor.sealUndo()
		updateTitle()
	}

	// MARK: Format changes (Format menu)

	func setLineEnding(_ eol: LineEnding) {
		guard format.lineEnding != eol || mixedLineEndings else { return }
		format.lineEnding = eol
		mixedLineEndings = false
		markEdited()
		updateTitle()
	}

	func setIndent(style: IndentStyle, size: Int) {
		format.indentStyle = style
		format.indentSize = size
		editor.format = format
		updateTitle()
	}

	func setTabWidth(_ width: Int) {
		format.tabWidth = width
		editor.format = format
		updateTitle()
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
		window.makeFirstResponder(editor)
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
		let s = editor.selections.primary
		guard !s.isEmpty else { return }
		find.replacement = editor.rope.string(in: s.range)
		findBar.syncFromController()
	}

	// MARK: Saving

	@discardableResult
	func save() -> Bool {
		guard let url else { return saveAs() }
		return write(to: url)
	}

	@discardableResult
	func saveAs() -> Bool {
		let panel = NSSavePanel()
		panel.nameFieldStringValue = url?.lastPathComponent ?? L("Untitled")
		if let dir = url?.deletingLastPathComponent() { panel.directoryURL = dir }
		guard panel.runModal() == .OK, let chosen = panel.url else { return false }
		url = chosen
		return write(to: chosen)
	}

	private func write(to url: URL) -> Bool {
		do {
			try TextFile.write(TextFile.save(editor.rope.string, settings: format, originalLines: originalLines), to: url)
			// Saved content becomes the new baseline for "trim modified lines".
			originalLines = Set(editor.rope.string.split(separator: "\n", omittingEmptySubsequences: false))
			window.isDocumentEdited = false
			diskStamp = FileStamp(url)
			diskBanner.isHidden = true
			editor.sealUndo()
			NSDocumentController.shared.noteNewRecentDocumentURL(url)
			updateTitle()
			return true
		} catch {
			NSAlert(error: error).beginSheetModal(for: window)
			return false
		}
	}

	/// Runs on every keystroke: touch the window only on the first change (setting the title
	/// each time cost 0.09 ms per key).
	private func markEdited() {
		guard !window.isDocumentEdited else { return }
		window.isDocumentEdited = true
	}

	/// Title shows what will be written: e.g. "User.php — LF · 4 spaces · UTF-8".
	func updateTitle() {
		let name = url?.lastPathComponent ?? L("Untitled")
		let indent = format.indentStyle == .tab ? L("Tabs (%d)", format.tabWidth) : LP("%d spaces", one: "%d space", format.indentSize)
		let eol = mixedLineEndings ? L("Mixed → %@", format.lineEnding.label) : format.lineEnding.label
		window.title = name
		window.subtitle = "\(eol) · \(indent) · \(format.charset.rawValue.uppercased())"
		window.representedURL = url
		window.tab.title = project.map { url == nil ? $0.name : name } ?? name
	}

	// MARK: Closing

	/// HIG save dialog as a sheet: Save (default) / Cancel / Don't Save. Completion gets true
	/// when the window may close.
	func confirmClose(_ completion: @escaping (Bool) -> Void) {
		guard window.isDocumentEdited else { return completion(true) }
		let alert = NSAlert()
		alert.messageText = L("Do you want to save the changes made to the document “%@”?", url?.lastPathComponent ?? L("Untitled"))
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
				case .alertFirstButtonReturn: completion(self.save())
				case .alertThirdButtonReturn:
					self.window.isDocumentEdited = false
					completion(true)
				default: completion(false)
				}
			}
		}
	}

	func windowShouldClose(_ sender: NSWindow) -> Bool {
		guard window.isDocumentEdited else { return true }
		confirmClose { [weak self] ok in
			if ok { self?.window.close() }
		}
		return false
	}
}

/// Identity of a file version on disk: modification date and size.
struct FileStamp: Equatable {
	let date: Date?
	let size: Int?

	init?(_ url: URL) {
		guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
		      values.contentModificationDate != nil else { return nil }
		date = values.contentModificationDate
		size = values.fileSize
	}
}

// MARK: Toolbar

extension DocumentWindow {
	static let findItem = NSToolbarItem.Identifier("find")
	static let bottomPanelItem = NSToolbarItem.Identifier("bottomPanel")

	func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
		project == nil ? [.flexibleSpace, Self.findItem]
			: [.toggleSidebar, .sidebarTrackingSeparator, .flexibleSpace, Self.findItem, Self.bottomPanelItem,
			   .inspectorTrackingSeparator, .flexibleSpace, .toggleInspector]
	}

	func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
		toolbarDefaultItemIdentifiers(toolbar)
	}

	func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
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
