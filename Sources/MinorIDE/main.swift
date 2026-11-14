import AppKit
import EditorKit
import MinorCore

// Usage: MinorIDE [file]        opens a file (phase-0 spike window)
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

	/// Editor of the most recently opened window (benchmark and snapshot use it).
	var editor: EditorView! { documents.last?.editor }

	func applicationDidFinishLaunching(_ notification: Notification) {
		buildMenu()
		let args = CommandLine.arguments.dropFirst()
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
		} else {
			openWindow(text: "// MinorIDE\nfunc main() {\n\tprintln(\"Příliš žluťoučký kůň\")\n}\n", title: "Untitled")
		}
		NSApp.activate()
	}

	func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

	/// Untitled window (also used by the benchmark).
	func openWindow(text: String, title: String) {
		add(DocumentWindow(text: text, url: nil, format: FormatSettings()))
	}

	func open(_ url: URL) {
		do {
			add(try DocumentWindow.open(url))
		} catch {
			NSAlert(error: error).runModal()
		}
	}

	private func add(_ doc: DocumentWindow) {
		documents.append(doc)
		doc.show()
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

	@objc func openDocument(_ sender: Any?) {
		let panel = NSOpenPanel()
		panel.allowsMultipleSelection = true
		guard panel.runModal() == .OK else { return }
		panel.urls.forEach(open)
	}

	@objc func saveDocument(_ sender: Any?) { current?.save() }

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

	/// Opens the user settings file, creating a template on first use.
	@objc func openUserSettings(_ sender: Any?) {
		let url = SettingsFile.userURL
		if !FileManager.default.fileExists(atPath: url.path) {
			try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
			try? Data(SettingsFile.template.utf8).write(to: url)
		}
		open(url)
	}

	func validateMenuItem(_ item: NSMenuItem) -> Bool {
		guard let doc = current else {
			return item.action == #selector(openDocument(_:)) || item.action == #selector(openUserSettings(_:))
				|| item.action == #selector(NSApplication.terminate(_:))
		}
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

	private func buildMenu() {
		let main = NSMenu()
		func submenu(_ title: String, in parent: NSMenu, _ build: (NSMenu) -> Void) {
			let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
			let menu = NSMenu(title: title)
			build(menu)
			item.submenu = menu
			parent.addItem(item)
		}
		submenu("MinorIDE", in: main) { m in
			m.addItem(withTitle: "Nastavení…", action: #selector(openUserSettings(_:)), keyEquivalent: ",")
			m.addItem(.separator())
			m.addItem(withTitle: "Ukončit MinorIDE", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
		}
		submenu("Soubor", in: main) { m in
			m.addItem(withTitle: "Otevřít…", action: #selector(openDocument(_:)), keyEquivalent: "o")
			m.addItem(withTitle: "Uložit", action: #selector(saveDocument(_:)), keyEquivalent: "s")
			m.addItem(withTitle: "Zavřít", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
		}
		submenu("Formát", in: main) { m in
			submenu("Konce řádků", in: m) { eol in
				for (title, value) in [("LF (Unix, macOS)", "lf"), ("CRLF (Windows)", "crlf"), ("CR (starý Mac)", "cr")] {
					eol.addItem(withTitle: title, action: #selector(setLineEnding(_:)), keyEquivalent: "").representedObject = value
				}
			}
			submenu("Odsazení", in: m) { indent in
				for (title, tag) in [("Tabulátor", 0), ("2 mezery", 2), ("4 mezery", 4)] {
					indent.addItem(withTitle: title, action: #selector(setIndent(_:)), keyEquivalent: "").tag = tag
				}
			}
			submenu("Šířka tabulátoru", in: m) { width in
				for w in [2, 4, 8] {
					width.addItem(withTitle: "\(w)", action: #selector(setTabWidth(_:)), keyEquivalent: "").tag = w
				}
			}
		}
		NSApp.mainMenu = main
	}
}
