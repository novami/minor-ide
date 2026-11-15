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
		if let file = args.first {
			open(URL(fileURLWithPath: file))
		} else if documents.isEmpty {
			newDocument(nil)
		}
		NSApp.activate()
	}

	func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

	/// Untitled window (also used by the benchmark).
	func openWindow(text: String, title: String) {
		add(DocumentWindow(text: text, url: nil, format: FormatSettings()))
	}

	/// Opens a file or a folder (project), or brings its window to front when already open.
	/// A file inside an open project opens as a tab of that project's window.
	func open(_ url: URL) {
		let isFolder = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
		if isFolder { return openProject(url) }
		if let existing = documents.first(where: { $0.url?.standardizedFileURL == url.standardizedFileURL }) {
			existing.show()
			return
		}
		if let handle = try? FileHandle(forReadingFrom: url) {
			let head = (try? handle.read(upToCount: 8192)) ?? Data()
			try? handle.close()
			if TextFile.looksBinary(head) { return refuseBinary(url) }
		}
		let project = projects.first { $0.contains(url) }
		do {
			let doc = try DocumentWindow.open(url, project: project)
			if let project { addTab(doc, in: project) } else { add(doc) }
			NSDocumentController.shared.noteNewRecentDocumentURL(url)
		} catch {
			NSAlert(error: error).runModal()
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

	/// Windows of renamed files (or files in a renamed folder) follow the new path.
	func filesMoved(from old: URL, to new: URL) {
		let oldPath = old.standardizedFileURL.path
		for doc in documents {
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
		let folders = Set(documents.filter { $0.project == nil }.compactMap { $0.url?.deletingLastPathComponent().path })
		looseWatcher = FileWatcher(paths: Array(folders)) { [weak self] paths in
			let changed = Set(paths.map { URL(fileURLWithPath: $0).standardizedFileURL.path })
			self?.documents.filter { $0.project == nil && ($0.url.map { changed.contains($0.standardizedFileURL.path) } ?? false) }.forEach { $0.checkDisk() }
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
		documents.forEach { $0.checkDisk() } // git checkout or another editor while away
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
		project.onFiles = { [weak self] paths in
			let changed = Set(paths.map { URL(fileURLWithPath: $0).standardizedFileURL.path })
			self?.documents.filter { $0.url.map { changed.contains($0.standardizedFileURL.path) } ?? false }.forEach { $0.checkDisk() }
		}
		projects.append(project)
		add(DocumentWindow(text: "", url: nil, format: FormatSettings(), project: project))
		NSDocumentController.shared.noteNewRecentDocumentURL(root)
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
		if host.url == nil && !host.window.isDocumentEdited && host.editor.rope.isEmpty { host.window.close() }
	}

	private func add(_ doc: DocumentWindow) {
		let previous = documents.last?.window
		documents.append(doc)
		doc.show(after: previous)
		observeClose(doc)
		if doc.project == nil && doc.url != nil { watchLooseFiles() }
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

	/// Opens the user settings file, creating a template on first use. A Settings window
	/// over the same file replaces this in phase 1e.
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
		let edited = documents.filter { $0.window.isDocumentEdited }
		guard !edited.isEmpty, !utilityMode else { return .terminateNow } // benchmark windows are scratch
		confirmNext(edited[...])
		return .terminateLater
	}

	private func confirmNext(_ remaining: ArraySlice<DocumentWindow>) {
		guard let doc = remaining.first else {
			NSApp.reply(toApplicationShouldTerminate: true)
			return
		}
		doc.show()
		doc.confirmClose { [weak self] ok in
			if ok {
				self?.confirmNext(remaining.dropFirst())
			} else {
				NSApp.reply(toApplicationShouldTerminate: false)
			}
		}
	}
}
