import AppKit
import EditorKit
import MinorCore

// Usage: MinorIDE [file]        opens a file (phase-0 spike window)
//        MinorIDE --dump-menu   prints the menu bar (add -AppleLanguages "(cs)" to check Czech)
//        MinorIDE --l10n-sample prints plural forms for several counts (same -AppleLanguages trick)
//        MinorIDE --bench       runs the editor spike benchmark and prints results
//        MinorIDE --snapshot <png> [file]   renders the editor to a PNG (visual check)
//        MINORIDE_FONT_SIZE=40 enlarges the font, useful with --snapshot
//        MINORIDE_FIND=<query> with --snapshot opens Find and Replace and saves the bar too
//        MINORIDE_FOLD=<line> with --snapshot folds the region headed by that line
//        MINORIDE_SPLIT=right|down with --snapshot splits the editor and prints the pane frames
//        MINORIDE_HISTORY=1 with --snapshot shows Local History of the file (temporary versions)
//        MINORIDE_WELCOME=1 with --snapshot saves the welcome window and prints its frames
//        MINORIDE_SETTINGS=<tab> with --snapshot saves that Settings tab (0 General, 1 Formatting)

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
	private var documents: [DocumentWindow] = []
	/// Benchmark/snapshot runs ignore files AppKit passes from the command line. Set at init:
	/// AppKit delivers files to open before applicationDidFinishLaunching.
	private let utilityMode = ["--bench", "--snapshot", "--dump-menu", "--l10n-sample"].contains(CommandLine.arguments.dropFirst().first ?? "")

	/// Editor of the most recently opened window (benchmark and snapshot use it).
	var editor: EditorView! { documents.last?.editor }

	func applicationDidFinishLaunching(_ notification: Notification) {
		NSApp.mainMenu = MainMenu.build(target: self)
		let args = CommandLine.arguments.dropFirst()
		if utilityMode { setvbuf(stdout, nil, _IOLBF, 0) } // results survive even if the run is killed
		if args.first == "--l10n-sample" { // prints plural forms (checks .stringsdict in the bundle)
			print([0, 1, 2, 3, 4, 5, 11, 21, 22, 25, 101].map { LP("%d spaces", one: "%d space", $0) }.joined(separator: ", "))
			NSApp.terminate(nil)
			return
		}
		if args.first == "--dump-menu" { // prints the menu bar (checks structure and localization)
			for item in NSApp.mainMenu?.items ?? [] {
				let sub = item.submenu?.items.map { $0.isSeparatorItem ? "—" : $0.title + ($0.keyEquivalent.isEmpty ? "" : " ⌘" + $0.keyEquivalent)
					+ ($0.isAlternate ? " (alt)" : "") + ($0.isHidden ? " (hidden)" : "") } ?? []
				print("\(item.submenu?.title ?? item.title): \(sub.joined(separator: " | "))")
			}
			NSApp.terminate(nil)
			return
		}
		if args.first == "--bench" {
			Bench.run(self)
			return
		}
		if args.first == "--snapshot", args.count >= 2, ProcessInfo.processInfo.environment["MINORIDE_WELCOME"] != nil {
			showWelcome(nil)
			WelcomeWindow.shared.snapshot(to: args[args.startIndex + 1])
			NSApp.terminate(nil)
			return
		}
		if args.first == "--snapshot", args.count >= 2, let tab = ProcessInfo.processInfo.environment["MINORIDE_SETTINGS"].flatMap(Int.init) {
			SettingsWindow.shared.snapshot(tab: tab, to: args[args.startIndex + 1])
			NSApp.terminate(nil)
			return
		}
		if args.first == "--snapshot", args.count >= 2 {
			if let file = args.dropFirst(2).first {
				open(URL(fileURLWithPath: file))
			} else {
				openWindow(text: Bench.snapshotText, title: "snapshot")
			}
			snapshot(to: args[args.startIndex + 1])
			print(documents.last?.window.title ?? "")
			NSApp.terminate(nil)
			return
		}
		watchUserSettings()
		observeFocusForAutoSave()
		if !utilityMode {
			let history = LocalHistory()
			FileDocument.history = history
			Task.detached(priority: .utility) { history.prune() }
		}
		if let file = args.first {
			open(URL(fileURLWithPath: file))
		} else if documents.isEmpty {
			showWelcome(nil)
		}
		NSApp.activate()
	}

	func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

	/// Untitled window (also used by the benchmark).
	func openWindow(text: String, title: String) {
		add(DocumentWindow(text: text))
	}

	/// Opens a file or a folder (project), or brings its window to front when already open.
	/// A file inside an open project opens as a tab of that project's window.
	func open(_ url: URL) {
		let isFolder = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
		if isFolder { return openProject(url) }
		if let existing = documents.first(where: { $0.pane(showing: url) != nil }) {
			existing.show()
			existing.focus(url)
			return
		}
		guard let file = loadText(url) else { return }
		let project = projects.first { $0.contains(url) }
		let doc = DocumentWindow(document: file, project: project)
		if let project { addTab(doc, in: project) } else { add(doc) }
		NSDocumentController.shared.noteNewRecentDocumentURL(url)
	}

	/// Opens a file of the project in the other pane of `window`'s editor.
	func open(_ url: URL, inSplitOf window: DocumentWindow) {
		guard let file = loadText(url) else { return }
		window.openInSplit(file)
		NSDocumentController.shared.noteNewRecentDocumentURL(url)
	}

	/// The open document of a file, or the file loaded; nil (after telling the user) for a
	/// binary file or a read error.
	private func loadText(_ url: URL) -> FileDocument? {
		if let open = FileDocument.document(for: url) { return open }
		if let handle = try? FileHandle(forReadingFrom: url) {
			let head = (try? handle.read(upToCount: 8192)) ?? Data()
			try? handle.close()
			if TextFile.looksBinary(head) {
				refuseBinary(url)
				return nil
			}
		}
		do {
			return try FileDocument.load(url)
		} catch {
			NSAlert(error: error).runModal()
			return nil
		}
	}

	/// Binary files are not opened as text; Finder (Space for Quick Look) can show them.
	private func refuseBinary(_ url: URL) {
		let alert = NSAlert()
		alert.messageText = L("“%@” is not a text file.", url.lastPathComponent)
		alert.informativeText = L("MinorIDE edits text files only. You can view its bytes or preview it in the Finder with Quick Look.")
		alert.addButton(withTitle: L("Show Hex"))
		alert.addButton(withTitle: L("Cancel"))
		alert.addButton(withTitle: L("Show in Finder"))
		let respond = { [weak self] (response: NSApplication.ModalResponse) in
			switch response {
			case .alertFirstButtonReturn: self?.showHex(url)
			case .alertThirdButtonReturn: NSWorkspace.shared.activateFileViewerSelecting([url])
			default: break
			}
		}
		if let window = NSApp.keyWindow {
			alert.beginSheetModal(for: window) { response in MainActor.assumeIsolated { respond(response) } }
		} else {
			respond(alert.runModal())
		}
	}

	private var hexWindows: [HexWindow] = []

	private func showHex(_ url: URL) {
		let hex = HexWindow(url: url)
		hex.onClose = { [weak self, weak hex] in self?.hexWindows.removeAll { $0 === hex } }
		hexWindows.append(hex)
	}

	private var projects: [Project] = []

	/// Renamed files (or files in a renamed folder) follow the new path.
	func filesMoved(from old: URL, to new: URL) {
		let oldPath = old.standardizedFileURL.path
		for doc in FileDocument.all {
			guard let path = doc.url?.standardizedFileURL.path else { continue }
			if path == oldPath {
				doc.fileMoved(to: new)
			} else if path.hasPrefix(oldPath + "/") {
				doc.fileMoved(to: URL(fileURLWithPath: new.path + path.dropFirst(oldPath.count)))
			}
		}
	}
	/// Folders of open files outside projects, watched for changes on disk.
	private var looseWatcher: FileWatcher?

	private func watchLooseFiles() {
		looseWatcher?.stop()
		let files = documents.filter { $0.project == nil }.flatMap(\.documents)
		let folders = Set(files.compactMap { $0.url?.deletingLastPathComponent().path })
		looseWatcher = FileWatcher(paths: Array(folders)) { paths in
			Self.checkDisk(changed: paths)
		}
	}
	/// Files of closed windows, newest last (File › Reopen Closed Tab).
	private var closedFiles: [URL] = []

	@objc func reopenClosedTab(_ sender: Any?) {
		while let url = closedFiles.popLast() {
			guard FileManager.default.fileExists(atPath: url.path) else { continue }
			return open(url)
		}
	}

	func applicationDidBecomeActive(_ notification: Notification) {
		FileDocument.all.forEach { $0.checkDisk() } // git checkout or another editor while away
	}

	/// Opens a folder in a project window with the file tree; an empty editor until a file
	/// is opened, which then replaces it.
	func openProject(_ url: URL) {
		let root = url.standardizedFileURL
		if let doc = documents.first(where: { $0.project?.url == root }) {
			doc.show()
			return
		}
		let project = Project(root: root)
		project.onFiles = { paths in Self.checkDisk(changed: paths) }
		projects.append(project)
		add(DocumentWindow(text: "", project: project))
		NSDocumentController.shared.noteNewRecentDocumentURL(root)
	}

	/// Open files among `paths` (FSEvents) compare themselves with the disk; a changed
	/// settings file re-resolves the format of every open file.
	private static func checkDisk(changed paths: [String]) {
		let changed = Set(paths.map { URL(fileURLWithPath: $0).standardizedFileURL.path })
		if changed.contains(where: isSettingsFile) { FileDocument.all.forEach { $0.settingsChanged() } }
		FileDocument.all.filter { $0.url.map { changed.contains($0.standardizedFileURL.path) } ?? false }.forEach { $0.checkDisk() }
	}

	private static func isSettingsFile(_ path: String) -> Bool {
		path.hasSuffix("/.editorconfig") || path.hasSuffix("/.minoride/settings.json") || path == SettingsFile.userURL.standardizedFileURL.path
	}

	/// Auto-save (settings.json "auto_save"): a window losing focus (another tab or window)
	/// saves its files, the app losing focus saves all.
	private func observeFocusForAutoSave() {
		let center = NotificationCenter.default
		center.addObserver(forName: NSWindow.didResignKeyNotification, object: nil, queue: .main) { [weak self] note in
			// A sheet taking focus (Save changes?) must not save before the user answers.
			guard let window = note.object as? NSWindow, window.attachedSheet == nil else { return }
			let id = ObjectIdentifier(window)
			MainActor.assumeIsolated {
				guard let self, Self.autoSaveEnabled else { return }
				self.documents.first { ObjectIdentifier($0.window) == id }?.documents.forEach { $0.autoSave() }
			}
		}
		center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { _ in
			MainActor.assumeIsolated {
				guard Self.autoSaveEnabled else { return }
				FileDocument.all.forEach { $0.autoSave() }
			}
		}
	}

	private static var autoSaveEnabled: Bool { SettingsFile.load(SettingsFile.userURL)?.autoSave ?? false }

	/// User settings (settings.json in Application Support), watched while the app runs.
	private var settingsWatcher: FileWatcher?

	private func watchUserSettings() {
		let folder = SettingsFile.userURL.deletingLastPathComponent()
		try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
		settingsWatcher = FileWatcher(paths: [folder.path]) { paths in Self.checkDisk(changed: paths) }
	}

	/// Adds a file's window as a tab of the project's window group.
	private func addTab(_ doc: DocumentWindow, in project: Project) {
		let host = documents.first { $0.project === project && $0.window.isKeyWindow }
			?? documents.last { $0.project === project }
		guard let host else { return add(doc) }
		documents.append(doc)
		observeClose(doc)
		host.window.addTabbedWindow(doc.window, ordered: .above)
		doc.showAsTab()
		// The empty editor a project opens with gives way to the first file.
		if host.panes.count == 1 && host.url == nil && !host.document.isEdited && host.editor.rope.isEmpty { host.window.close() }
	}

	private func add(_ doc: DocumentWindow) {
		let previous = documents.last?.window
		documents.append(doc)
		doc.show(after: previous)
		observeClose(doc)
		if doc.project == nil && doc.url != nil { watchLooseFiles() }
		WelcomeWindow.shared.close() // after the new window shows, so the app does not quit
	}

	private func observeClose(_ doc: DocumentWindow) {
		NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: doc.window, queue: .main) { [weak self, weak doc] _ in
			MainActor.assumeIsolated {
				guard let self else { return }
				let project = doc?.project
				if let url = doc?.url { self.closedFiles.append(url) }
				self.documents.removeAll { $0 === doc }
				if project == nil { self.watchLooseFiles() }
				// The last window of a project closes the project (stops watching its files).
				if let project, !self.documents.contains(where: { $0.project === project }) {
					project.close()
					self.projects.removeAll { $0 === project }
				}
			}
		}
	}

	private var current: DocumentWindow? {
		documents.first { $0.window == NSApp.keyWindow } ?? documents.last
	}

	/// Gutter and visible text composed by hand (cacheDisplay of the scroll view ignores the
	/// ruler's content inset), plus the caret layer that cacheDisplay skips.
	func snapshot(to path: String) {
		guard let view = editor.enclosingScrollView else { return }
		// A project window is also saved whole as <png>-window.png (sidebar included);
		// MINORIDE_OPEN=<file> opens a file of the project first.
		if let doc = documents.last, doc.project != nil {
			if let file = ProcessInfo.processInfo.environment["MINORIDE_OPEN"] { open(URL(fileURLWithPath: file)) }
			let window = (documents.last ?? doc).window
			window.displayIfNeeded()
			if let content = window.contentView, let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
				content.cacheDisplay(in: content.bounds, to: rep)
				try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path.replacingOccurrences(of: ".png", with: "-window.png")))
			}
		}
		// MINORIDE_FOLD=<line> folds the region headed by that line (1-based).
		if let line = ProcessInfo.processInfo.environment["MINORIDE_FOLD"].flatMap(Int.init) { editor.toggleFold(atLine: line - 1) }
		if let split = ProcessInfo.processInfo.environment["MINORIDE_SPLIT"], let doc = documents.last {
			doc.split(vertical: split != "down")
			for pane in [doc.editor, doc.splitEditor].compactMap({ $0 }) {
				print("pane", pane.enclosingScrollView.map { NSStringFromRect($0.convert($0.bounds, to: nil)) } ?? "-",
				      "editor", NSStringFromSize(pane.frame.size), "caret", pane.caret, "first responder", doc.window.firstResponder === pane)
			}
		}
		// MINORIDE_HISTORY=1 fills a temporary Local History with two versions of the file and
		// also saves its window as <png>-history.png (the file itself is not written).
		if ProcessInfo.processInfo.environment["MINORIDE_HISTORY"] != nil, let doc = documents.last, let url = doc.url {
			let history = LocalHistory(root: FileManager.default.temporaryDirectory.appendingPathComponent("MinorIDE-history-\(UUID().uuidString)"))
			FileDocument.history = history
			let text = doc.document.text.rope.string
			try? history.record(Data(("// older\n" + text).utf8), for: url.standardizedFileURL.path, date: Date().addingTimeInterval(-90_000))
			try? history.record(Data(text.replacingOccurrences(of: "\n", with: "\n\n", options: [], range: text.range(of: "\n")).utf8), for: url.standardizedFileURL.path)
			doc.showLocalHistory(nil)
			if let window = NSApp.windows.first(where: { $0.subtitle == L("Local History") }), let content = window.contentView {
				window.displayIfNeeded()
				print("history", NSStringFromSize(content.bounds.size), doc.document.versions.count)
				if let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
					content.cacheDisplay(in: content.bounds, to: rep)
					try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path.replacingOccurrences(of: ".png", with: "-history.png")))
				}
			}
			try? FileManager.default.removeItem(at: history.root)
		}
		// MINORIDE_FIND=<query> opens Find and Replace first and also saves the bar as <png>-find.png.
		if let query = ProcessInfo.processInfo.environment["MINORIDE_FIND"], let doc = documents.last {
			doc.showFindBar(replace: true)
			doc.find.origin = 0
			doc.find.query.text = query
			doc.findBarView.syncFromController()
			let deadline = Date().addingTimeInterval(2)
			while doc.find.matches.isEmpty && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
			doc.findBarView.updateStatus()
			doc.window.displayIfNeeded()
			let bar = doc.findBarView
			if let rep = bar.bitmapImageRepForCachingDisplay(in: bar.bounds) {
				bar.cacheDisplay(in: bar.bounds, to: rep)
				try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path.replacingOccurrences(of: ".png", with: "-find.png")))
			}
		}
		editor.window?.makeFirstResponder(editor)
		editor.window?.displayIfNeeded()
		guard let canvas = view.bitmapImageRepForCachingDisplay(in: view.bounds),
		      let ctx = NSGraphicsContext(bitmapImageRep: canvas) else { return }
		NSGraphicsContext.current = ctx
		ctx.cgContext.scaleBy(x: CGFloat(canvas.pixelsWide) / view.bounds.width, y: CGFloat(canvas.pixelsHigh) / view.bounds.height)
		// The bitmap context is not flipped; the scroll view may be.
		func canvasY(_ y: CGFloat) -> CGFloat { view.isFlipped ? view.bounds.height - y : y }
		NSColor.textBackgroundColor.setFill()
		view.bounds.fill()
		for part in [editor, editor.gutter] as [NSView?] { // the gutter floats over the text's inset
			// The ruler is not clipped by the scroll view, so its visibleRect can exceed its bounds.
			let visible = part?.visibleRect.intersection(part?.bounds ?? .zero) ?? .zero
			guard let part, let rep = part.bitmapImageRepForCachingDisplay(in: visible) else { continue }
			part.cacheDisplay(in: visible, to: rep)
			let r = part.convert(visible, to: view)
			rep.draw(in: NSRect(x: r.minX, y: canvasY(r.maxY), width: r.width, height: r.height))
		}
		let origin = editor.convert(NSPoint.zero, to: view)
		ctx.cgContext.translateBy(x: origin.x, y: canvasY(origin.y))
		ctx.cgContext.scaleBy(x: 1, y: canvasY(editor.convert(NSPoint(x: 0, y: 1), to: view).y) - canvasY(origin.y))
		editor.renderCarets(in: ctx.cgContext)
		NSGraphicsContext.current = nil
		try? canvas.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
	}

	// MARK: Menu actions

	@objc func newDocument(_ sender: Any?) {
		openWindow(text: "", title: "")
	}

	@objc func openDocument(_ sender: Any?) {
		let panel = NSOpenPanel()
		panel.allowsMultipleSelection = true
		panel.canChooseDirectories = true
		guard panel.runModal() == .OK else { return }
		panel.urls.forEach(open)
	}

	/// Window › Welcome to MinorIDE; also at launch with nothing to open.
	@objc func showWelcome(_ sender: Any?) {
		WelcomeWindow.shared.target = self
		WelcomeWindow.shared.show()
	}

	/// Dock icon clicked with no window open.
	func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
		if !flag && !utilityMode { showWelcome(nil) }
		return false
	}

	@objc func openRecent(_ sender: NSMenuItem) {
		if let url = sender.representedObject as? URL { open(url) }
	}

	@objc func saveDocument(_ sender: Any?) {
		let wasUntitled = current?.url == nil
		if current?.save() == true, wasUntitled { watchLooseFiles() }
	}

	@objc func saveDocumentAs(_ sender: Any?) {
		if current?.saveAs() == true { watchLooseFiles() }
	}

	@objc func setLineEnding(_ sender: NSMenuItem) {
		if let eol = sender.representedObject as? String, let value = LineEnding(rawValue: eol) {
			current?.setLineEnding(value)
		}
	}

	/// Tag 0 = tabs, otherwise the number of spaces.
	@objc func setIndent(_ sender: NSMenuItem) {
		guard let doc = current else { return }
		doc.setIndent(style: sender.tag == 0 ? .tab : .space, size: sender.tag == 0 ? doc.format.indentSize : sender.tag)
	}

	@objc func setTabWidth(_ sender: NSMenuItem) { current?.setTabWidth(sender.tag) }

	@objc func showSettings(_ sender: Any?) { SettingsWindow.shared.show() }

	/// Opens the user settings file, creating a template on first use (Settings window).
	@objc func openUserSettings(_ sender: Any?) {
		let url = SettingsFile.userURL
		if !FileManager.default.fileExists(atPath: url.path) {
			try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
			try? Data(SettingsFile.template.utf8).write(to: url)
		}
		open(url)
	}

	func validateMenuItem(_ item: NSMenuItem) -> Bool {
		if item.action == #selector(reopenClosedTab(_:)) { return !closedFiles.isEmpty }
		let needsDocument: Set<Selector?> = [#selector(saveDocument(_:)), #selector(saveDocumentAs(_:)),
		                                    #selector(setLineEnding(_:)), #selector(setIndent(_:)), #selector(setTabWidth(_:))]
		guard let doc = current else { return !needsDocument.contains(item.action) }
		switch item.action {
		case #selector(setLineEnding(_:)):
			item.state = (item.representedObject as? String) == doc.format.lineEnding.rawValue && !doc.mixedLineEndings ? .on : .off
		case #selector(setIndent(_:)):
			let tabs = doc.format.indentStyle == .tab
			item.state = (item.tag == 0 && tabs) || (!tabs && item.tag == doc.format.indentSize) ? .on : .off
		case #selector(setTabWidth(_:)):
			item.state = item.tag == doc.format.tabWidth ? .on : .off
		default: break
		}
		return true
	}

	// MARK: Finder, Dock and quitting

	/// Files dropped on the Dock icon or opened from Finder ("Open With").
	func application(_ application: NSApplication, open urls: [URL]) {
		guard !utilityMode else { return }
		urls.forEach(open)
	}

	/// Asks about unsaved documents one by one, each as a sheet on its window.
	func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
		let edited = documents.filter { window in window.documents.contains(where: \.isEdited) }
		guard !edited.isEmpty, !utilityMode else { return .terminateNow } // benchmark windows are scratch
		confirmNext(edited[...])
		return .terminateLater
	}

	/// Each window asks about its edited files; a file shown in several windows is asked once
	/// (Don't Save clears its edited flag, Save saves it).
	private func confirmNext(_ remaining: ArraySlice<DocumentWindow>) {
		guard let doc = remaining.first else {
			NSApp.reply(toApplicationShouldTerminate: true)
			return
		}
		guard doc.documents.contains(where: \.isEdited) else { return confirmNext(remaining.dropFirst()) }
		doc.show()
		doc.confirmEdited { [weak self] ok in
			if ok {
				self?.confirmNext(remaining.dropFirst())
			} else {
				NSApp.reply(toApplicationShouldTerminate: false)
			}
		}
	}
}
