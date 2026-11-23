import AppKit
import Localization
import EditorKit
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
		add(GeneralSettingsView(store: store), Strings.settings.general, "gearshape")
		add(FormatSettingsView(store: store), Strings.settings.formatting, "text.alignleft")
		add(ToolsSettingsView(model: ToolsModel.shared), Strings.settings.tools, "hammer")
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
	private static let installedFamilies = EditorView.monospacedFamilies

	/// Installed monospaced families, plus one written by hand in settings.json.
	private var families: [String] {
		guard let f = store.file.fontFamily, !Self.installedFamilies.contains(f) else { return Self.installedFamilies }
		return Self.installedFamilies + [f]
	}

	/// Sizes offered, plus one written by hand in settings.json.
	private var sizes: [Int] {
		let set = Set([9, 10, 11, 12, 13, 14, 15, 16, 18, 20, 22, 24] + [store.file.fontSize.map { Int($0) }].compactMap { $0 })
		return set.sorted()
	}

	/// Open editors change at once; the file watcher would follow a moment later.
	private func applyFont() {
		AppDelegate.loadEditorSettings()
	}

	var body: some View {
		Form {
			Section {
				Picker(Strings.settings.font, selection: Binding(
					get: { store.file.fontFamily ?? "" },
					set: { store.set(nil, "font_family", $0.isEmpty ? nil : .string($0)); applyFont() })) {
					Text(Strings.settings.automatic).tag("")
					Divider()
					ForEach(families, id: \.self) { Text($0).tag($0) }
				}
				Picker(Strings.settings.size, selection: Binding(
					get: { Int(store.file.fontSize ?? Double(EditorView.defaultFontSize)) },
					set: { store.set(nil, "font_size", $0 == Int(EditorView.defaultFontSize) ? nil : .number(Double($0))); applyFont() })) {
					ForEach(sizes, id: \.self) { Text("\($0)").tag($0) }
				}
				Text(Strings.settings.automaticFontInfo)
					.font(.callout).foregroundStyle(.secondary)
			}
			.disabled(store.unreadable)
			Section {
				Toggle(Strings.settings.detectIndentationFile, isOn: Binding(
					get: { store.file.detectIndent ?? true },
					set: { store.set(nil, "detect_indent", .bool($0)) }))
				Text(Strings.settings.detectIndentationInfo)
					.font(.callout).foregroundStyle(.secondary)
			}
			.disabled(store.unreadable)
			Section {
				Toggle(Strings.settings.saveFilesAutomatically, isOn: Binding(
					get: { store.file.autoSave ?? false },
					set: { store.set(nil, "auto_save", .bool($0)) }))
				Text(Strings.settings.autosaveInfo)
					.font(.callout).foregroundStyle(.secondary)
			}
			.disabled(store.unreadable)
			Section {
				Toggle(Strings.settings.wrapLines, isOn: Binding(
					get: { store.file.wrapLines ?? false },
					set: { on in
						store.set(nil, "wrap_lines", .bool(on))
						EditorView.wrapsLines = on
					}))
				Text(Strings.settings.wrapLinesInfo)
					.font(.callout).foregroundStyle(.secondary)
			}
			.disabled(store.unreadable)
			Section {
				Toggle(Strings.settings.pinEnclosingLines, isOn: Binding(
					get: { store.file.stickyLines ?? true },
					set: { on in
						store.set(nil, "sticky_lines", .bool(on))
						EditorView.showsStickyLines = on
					}))
				Text(Strings.settings.pinEnclosingLinesInfo)
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
				Label(Strings.settings.invalidSettingsFile,
				      systemImage: "exclamationmark.triangle.fill")
					.foregroundStyle(.orange)
			}
			HStack {
				Text(Strings.settings.settingsFileInfo)
					.font(.callout).foregroundStyle(.secondary)
				Spacer()
				Button(Strings.settings.openSettingsJson) { NSApp.sendAction(#selector(AppDelegate.openUserSettings(_:)), to: nil, from: nil) }
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
				Picker(Strings.settings.language, selection: Binding(get: { store.section }, set: { store.section = $0 })) {
					Text(Strings.settings.allLanguages).tag("*")
					Divider()
					ForEach(Self.languages, id: \.0) { Text($0.1).tag($0.0) }
					Divider()
					Text(Strings.format.plainText).tag("text")
				}
			} footer: {
				Text(section == "*"
					? Strings.settings.allLanguagesInfo
					: Strings.settings.languageOverrideInfo)
			}
			.disabled(store.unreadable)
			Section {
				if section == "php" {
					row(Strings.settings.codingStandard, "preset", [("psr12", "PSR-12"), ("nette", "Nette")])
				}
				row(Strings.settings.indentWith, "indent_style", [("tab", Strings.format.tabs), ("space", Strings.settings.spaces)])
				row(Strings.settings.indentSize, "indent_size", numbers(1...8), number: true)
				row(Strings.settings.tabWidth, "tab_width", numbers(1...8), number: true)
				row(Strings.settings.lineLength, "max_line_length", [80, 100, 120, 160].map { ("\($0)", "\($0)") } + [("off", Strings.settings.notSet)], number: true)
				row(Strings.settings.lineEndings, "end_of_line", [("lf", Strings.format.lineEndingLF), ("crlf", Strings.format.lineEndingCRLF), ("cr", Strings.format.lineEndingCR)])
				row(Strings.format.encoding, "charset", Charset.allCases.map { ($0.rawValue, $0.rawValue.uppercased()) })
				row(Strings.settings.finalNewline, "insert_final_newline", [("true", Strings.common.add), ("false", Strings.settings.dontAdd)])
				row(Strings.settings.trailingSpaces, "trim_trailing_whitespace",
				    [("modified", Strings.settings.removeEditedLines), ("true", Strings.settings.removeAllLines), ("false", Strings.settings.keep)])
				row(Strings.settings.formatOnSave, "format_on_save", [("true", Strings.settings.formatTheFile), ("false", Strings.settings.dontFormat)])
			} footer: {
				Text(Strings.settings.codingStandardInfo)
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
			Text(Strings.settings.default).tag("")
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
