import AppKit
import EditorKit
import MinorCore

// Usage: MinorIDE [file]        opens a file (phase-0 spike window)
//        MinorIDE --dump-menu   prints the menu bar (add -AppleLanguages "(cs)" to check Czech)
//        MinorIDE --l10n-sample prints plural forms for several counts (same -AppleLanguages trick)
//        MinorIDE --bench       runs the editor spike benchmark and prints results
//        MinorIDE --snapshot <png> [file]   renders the editor to a PNG (visual check)
//        MINORIDE_FONT_SIZE=40 enlarges the font, useful with --snapshot

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

	/// Opens a file, or brings its window to front when it is already open.
	func open(_ url: URL) {
		if let existing = documents.first(where: { $0.url?.standardizedFileURL == url.standardizedFileURL }) {
			existing.show()
			return
		}
		do {
			add(try DocumentWindow.open(url))
			NSDocumentController.shared.noteNewRecentDocumentURL(url)
		} catch {
			NSAlert(error: error).runModal()
		}
	}

	private func add(_ doc: DocumentWindow) {
		let previous = documents.last?.window
		documents.append(doc)
		doc.show(after: previous)
		NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: doc.window, queue: .main) { [weak self, weak doc] _ in
			MainActor.assumeIsolated { self?.documents.removeAll { $0 === doc } }
		}
	}

	private var current: DocumentWindow? {
		documents.first { $0.window == NSApp.keyWindow } ?? documents.last
	}

	func snapshot(to path: String) {
		editor.displayIfNeeded()
		let rect = editor.visibleRect
		guard let rep = editor.bitmapImageRepForCachingDisplay(in: rect) else { return }
		editor.cacheDisplay(in: rect, to: rep)
		try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
	}

	// MARK: Menu actions

	@objc func newDocument(_ sender: Any?) {
		openWindow(text: "", title: "")
	}

	@objc func openDocument(_ sender: Any?) {
		let panel = NSOpenPanel()
		panel.allowsMultipleSelection = true
		guard panel.runModal() == .OK else { return }
		panel.urls.forEach(open)
	}

	@objc func openRecent(_ sender: NSMenuItem) {
		if let url = sender.representedObject as? URL { open(url) }
	}

	@objc func saveDocument(_ sender: Any?) { current?.save() }

	@objc func saveDocumentAs(_ sender: Any?) { current?.saveAs() }

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
