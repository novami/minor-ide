import AppKit
import EditorKit
import Highlight
import MinorCore

/// One editor window bound to a file (or untitled). Holds what is needed to save the file
/// back in its own conventions: line ending, charset and the lines as loaded.
@MainActor
final class DocumentWindow: NSObject, NSWindowDelegate {
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

	init(text: String, url: URL?, format: FormatSettings) {
		self.url = url
		self.format = format
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
		let content = NSStackView(views: [findBar, scroll])
		content.orientation = .vertical
		content.spacing = 0
		content.alignment = .width
		content.distribution = .fill
		scroll.setContentHuggingPriority(.defaultLow, for: .vertical)
		findBar.setContentHuggingPriority(.required, for: .vertical)
		window.contentView = content
		window.isReleasedWhenClosed = false
		super.init()
		window.delegate = self
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
	static func open(_ url: URL) throws -> DocumentWindow {
		let loaded = TextFile.load(try Data(contentsOf: url))
		let resolved = Self.resolve(path: url.path, detected: loaded.detected)
		var format = resolved.settings
		format.charset = loaded.charset
		let doc = DocumentWindow(text: loaded.text, url: url, format: format)
		doc.editor.language = Languages.language(forPath: url.path)
		doc.resolved = resolved
		doc.originalLines = loaded.originalLines
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
		window.title = "\(name) — \(eol) · \(indent) · \(format.charset.rawValue.uppercased())"
		window.representedURL = url
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
