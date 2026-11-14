import AppKit
import EditorKit
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

	init(text: String, url: URL?, format: FormatSettings) {
		self.url = url
		self.format = format
		window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 800),
		                  styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
		let scroll = NSScrollView(frame: window.contentView!.bounds)
		scroll.autoresizingMask = [.width, .height]
		scroll.hasVerticalScroller = true
		let size = ProcessInfo.processInfo.environment["MINORIDE_FONT_SIZE"].flatMap(Double.init) ?? 13
		editor = EditorView(text: text, font: .monospacedSystemFont(ofSize: size, weight: .regular))
		editor.autoresizingMask = [.width]
		editor.format = format
		scroll.documentView = editor
		window.contentView = scroll
		window.isReleasedWhenClosed = false
		super.init()
		window.delegate = self
		editor.onChange = { [weak self] in self?.markEdited() }
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

	func show() {
		window.center()
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

	// MARK: Saving

	@discardableResult
	func save() -> Bool {
		if url == nil {
			let panel = NSSavePanel()
			guard panel.runModal() == .OK, let chosen = panel.url else { return false }
			url = chosen
		}
		guard let url else { return false }
		do {
			try TextFile.save(editor.rope.string, settings: format, originalLines: originalLines).write(to: url, options: .atomic)
			// Saved content becomes the new baseline for "trim modified lines".
			originalLines = Set(editor.rope.string.split(separator: "\n", omittingEmptySubsequences: false))
			window.isDocumentEdited = false
			updateTitle()
			return true
		} catch {
			NSAlert(error: error).runModal()
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
		let name = url?.lastPathComponent ?? "Untitled"
		let indent = format.indentStyle == .tab ? "Tab (\(format.tabWidth))" : "\(format.indentSize) spaces"
		let eol = mixedLineEndings ? "Mixed→\(format.lineEnding.label)" : format.lineEnding.label
		window.title = "\(name) — \(eol) · \(indent) · \(format.charset.rawValue.uppercased())"
		window.representedURL = url
	}

	func windowShouldClose(_ sender: NSWindow) -> Bool {
		guard window.isDocumentEdited else { return true }
		let alert = NSAlert()
		alert.messageText = "Uložit změny v \(url?.lastPathComponent ?? "Untitled")?"
		alert.addButton(withTitle: "Uložit")
		alert.addButton(withTitle: "Zrušit")
		alert.addButton(withTitle: "Neukládat")
		switch alert.runModal() {
		case .alertFirstButtonReturn: return save()
		case .alertThirdButtonReturn: return true
		default: return false
		}
	}
}
