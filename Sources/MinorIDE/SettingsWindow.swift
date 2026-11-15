import AppKit
import MinorCore
import SwiftUI

/// MinorIDE › Settings… (⌘,): tabs in the toolbar (HIG), changes saved to the user's
/// settings.json at once and applied to open files through its file watcher.
@MainActor
final class SettingsWindow: NSObject, NSWindowDelegate {
	static let shared = SettingsWindow()
	let store = SettingsStore()
	private var window: NSWindow?

	func show() {
		store.load()
		if ToolsModel.shared.checks.isEmpty { ToolsModel.shared.refresh() }
		if window == nil { window = makeWindow() }
		window?.makeKeyAndOrderFront(nil)
	}

	private func makeWindow() -> NSWindow {
		let tabs = SettingsTabs()
		tabs.tabStyle = .toolbar
		func add(_ view: some View, _ title: String, _ symbol: String) {
			let host = NSHostingController(rootView: view)
			host.sizingOptions = .preferredContentSize // the window takes each tab's size
			let item = NSTabViewItem(viewController: host)
			item.label = title
			item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
			tabs.addTabViewItem(item)
		}
		add(GeneralSettingsView(store: store), L("General"), "gearshape")
		add(FormatSettingsView(store: store), L("Formatting"), "text.alignleft")
		add(ToolsSettingsView(model: ToolsModel.shared), L("Tools"), "hammer")
		tabs.title = tabs.tabViewItems.first?.label
		let window = NSWindow(contentViewController: tabs) // its title follows tabs.title
		window.styleMask = [.titled, .closable]
		window.toolbarStyle = .preference
		window.isReleasedWhenClosed = false
		window.delegate = self
		window.center()
		return window
	}

	/// Saves one tab of the window (snapshot runs) and prints its size.
	func snapshot(tab: Int, to path: String) {
		show()
		(window?.contentViewController as? NSTabViewController)?.selectedTabViewItemIndex = tab
		let deadline = Date().addingTimeInterval(tab == 2 ? 8 : 1) // SwiftUI layout; tool checks run in the background
		while Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
		guard let window, let content = window.contentView else { return }
		window.displayIfNeeded()
		print(window.title, NSStringFromSize(content.bounds.size))
		if let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
			content.cacheDisplay(in: content.bounds, to: rep)
			try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
		}
	}

	/// The file may have been edited by hand meanwhile.
	func windowDidBecomeKey(_ notification: Notification) { store.load() }
}

/// The window title follows the selected tab (HIG).
final class SettingsTabs: NSTabViewController {
	override func tabView(_ tabView: NSTabView, didSelect item: NSTabViewItem?) {
		super.tabView(tabView, didSelect: item)
		if let item { title = item.label }
	}
}

/// The user's settings.json as the Settings window shows and changes it.
@MainActor @Observable
final class SettingsStore {
	private(set) var file = SettingsFile()
	/// settings.json is not valid JSON: the window does not overwrite it.
	private(set) var unreadable = false
	/// Section shown in Formatting: "*" or a language id. (A store property, not @State:
	/// SwiftUI's macros are not available with the Command Line Tools.)
	var section = "*"
	private let url: URL

	init(url: URL = SettingsFile.userURL) { self.url = url }

	func load() {
		guard let data = try? Data(contentsOf: url) else {
			file = SettingsFile()
			unreadable = false
			return
		}
		if let parsed = try? SettingsFile(json: data) {
			file = parsed
			unreadable = false
		} else {
			unreadable = true
		}
	}

	/// A format property of `section` ("*" or a language id) as written in the file.
	func value(_ section: String, _ key: String) -> String? { file.format[section]?[key] }

	/// `section` nil sets a top-level key; nil `value` removes the key (back to the default).
	func set(_ section: String?, _ key: String, _ value: JSONValue?) {
		do {
			try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
			let data = try SettingsFile.updating(try? Data(contentsOf: url), section: section, key: key, value: value)
			try data.write(to: url, options: .atomic)
			load()
		} catch {
			unreadable = true
		}
	}
}

struct GeneralSettingsView: View {
	let store: SettingsStore

	var body: some View {
		Form {
			Section {
				Toggle(L("Detect indentation from the file"), isOn: Binding(
					get: { store.file.detectIndent ?? true },
					set: { store.set(nil, "detect_indent", .bool($0)) }))
				Text(L("An existing file keeps the indentation it uses, unless .editorconfig or project settings say otherwise."))
					.font(.callout).foregroundStyle(.secondary)
			}
			.disabled(store.unreadable)
			Section {
				Toggle(L("Save files automatically"), isOn: Binding(
					get: { store.file.autoSave ?? false },
					set: { store.set(nil, "auto_save", .bool($0)) }))
				Text(L("Edited files are saved when you switch to another tab, window or app. Files changed on disk meanwhile are not saved. Every save is kept in Local History."))
					.font(.callout).foregroundStyle(.secondary)
			}
			.disabled(store.unreadable)
			SettingsFileSection(store: store)
		}
		.formStyle(.grouped)
		.frame(width: 520)
		.fixedSize(horizontal: false, vertical: true)
	}
}

/// Where the settings live, and a warning when the file cannot be read.
struct SettingsFileSection: View {
	let store: SettingsStore

	var body: some View {
		Section {
			if store.unreadable {
				Label(L("settings.json is not valid JSON. Fix it in the editor; until then these settings can’t be changed here."),
				      systemImage: "exclamationmark.triangle.fill")
					.foregroundStyle(.orange)
			}
			HStack {
				Text(L("Settings are stored in settings.json. A project can override them in .minoride/settings.json."))
					.font(.callout).foregroundStyle(.secondary)
				Spacer()
				Button(L("Open settings.json")) { NSApp.sendAction(#selector(AppDelegate.openUserSettings(_:)), to: nil, from: nil) }
			}
		}
	}
}

struct FormatSettingsView: View {
	let store: SettingsStore
	private var section: String { store.section }

	/// Language ids of settings.json (MinorCore.Language) with their names.
	private static let languages: [(String, String)] = [
		("php", "PHP"), ("go", "Go"), ("latte", "Latte"), ("neon", "NEON"), ("sql", "SQL"),
		("javascript", "JavaScript"), ("typescript", "TypeScript"), ("vue", "Vue"), ("json", "JSON"),
		("html", "HTML"), ("css", "CSS"), ("scss", "SCSS"), ("xml", "XML"), ("yaml", "YAML"),
		("markdown", "Markdown"), ("shell", "Shell"), ("makefile", "Makefile"), ("dockerfile", "Dockerfile"),
		("dotenv", ".env"), ("batch", "Batch"),
	]

	var body: some View {
		Form {
			Section {
				Picker(L("Language"), selection: Binding(get: { store.section }, set: { store.section = $0 })) {
					Text(L("All Languages")).tag("*")
					Divider()
					ForEach(Self.languages, id: \.0) { Text($0.1).tag($0.0) }
					Divider()
					Text(L("Plain Text")).tag("text")
				}
			} footer: {
				Text(section == "*"
					? L("Applies to every language unless the language sets its own value.")
					: L("Overrides All Languages for this language."))
			}
			.disabled(store.unreadable)
			Section {
				if section == "php" {
					row(L("Coding standard"), "preset", [("psr12", "PSR-12"), ("nette", "Nette")])
				}
				row(L("Indent with"), "indent_style", [("tab", L("Tabs")), ("space", L("Spaces"))])
				row(L("Indent size"), "indent_size", numbers(1...8), number: true)
				row(L("Tab width"), "tab_width", numbers(1...8), number: true)
				row(L("Line endings"), "end_of_line", [("lf", L("LF (macOS, Unix)")), ("crlf", L("CRLF (Windows)")), ("cr", L("CR (Classic Mac)"))])
				row(L("Encoding"), "charset", Charset.allCases.map { ($0.rawValue, $0.rawValue.uppercased()) })
				row(L("Newline at end of file"), "insert_final_newline", [("true", L("Add")), ("false", L("Don’t add"))])
				row(L("Trailing spaces"), "trim_trailing_whitespace",
				    [("modified", L("Remove from edited lines")), ("true", L("Remove from all lines")), ("false", L("Keep"))])
			} footer: {
				Text(L("Default follows the language’s standard, such as PSR-12 for PHP and gofmt for Go. A file’s own line endings, .editorconfig and project settings take precedence."))
			}
			.disabled(store.unreadable) // the file section stays usable: it opens the file to fix
			SettingsFileSection(store: store)
		}
		.formStyle(.grouped)
		.frame(width: 520)
		.fixedSize(horizontal: false, vertical: true)
	}

	private func numbers(_ range: ClosedRange<Int>) -> [(String, String)] { range.map { ("\($0)", "\($0)") } }

	/// A picker over one property: Default (key absent) or one of `options`; a value written
	/// by hand that is not among them is shown too.
	private func row(_ title: String, _ key: String, _ options: [(String, String)], number: Bool = false) -> some View {
		let current = store.value(section, key)
		var choices = options
		if let current, !choices.contains(where: { $0.0 == current }) { choices.append((current, current)) }
		return Picker(title, selection: Binding(
			get: { current ?? "" },
			set: { raw in store.set(section, key, raw.isEmpty ? nil : Self.json(raw, key: key)) })) {
			Text(L("Default")).tag("")
			Divider()
			ForEach(choices, id: \.0) { Text($0.1).tag($0.0) }
		}
	}

	/// Numbers and booleans are written as JSON numbers and booleans, like the template.
	private static func json(_ raw: String, key: String) -> JSONValue {
		if raw == "true" || raw == "false" { return .bool(raw == "true") }
		if let n = Double(raw), ["indent_size", "tab_width", "max_line_length"].contains(key) { return .number(n) }
		return .string(raw)
	}
}
