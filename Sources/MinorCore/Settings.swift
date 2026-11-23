import Foundation

/// Contents of settings.json (user: ~/Library/Application Support/MinorIDE/settings.json,
/// project: <root>/.minoride/settings.json). Example:
///
///     {
///       "detect_indent": true,
///       "format": {
///         "*":   { "end_of_line": "lf" },
///         "php": { "preset": "nette" },
///         "go":  { "tab_width": 8 }
///       }
///     }
public struct SettingsFile: Sendable, Equatable {
	/// Section ("*" or a language id) → EditorConfig-style properties, plus "preset".
	public var format: [String: [String: String]] = [:]
	public var detectIndent: Bool?
	/// Save edited files when their window or the app loses focus (off unless set).
	public var autoSave: Bool?
	/// Soft wrap long lines in every editor (off unless set).
	public var wrapLines: Bool?
	/// Pin the lines that open the enclosing blocks at the top of editors (on unless set).
	public var stickyLines: Bool?
	/// Editor font family and size (system monospaced, 13 unless set).
	public var fontFamily: String?
	public var fontSize: Double?
	/// UI language as a locale code ("cs-CZ"); nil or "system" follows the system. Applies after a restart.
	public var language: String?
	/// Check for app updates once a day (on unless set).
	public var autoCheckUpdates: Bool?
	/// Download a found update without asking (on unless set).
	public var autoDownloadUpdates: Bool?

	public init() {}

	public init(json data: Data) throws {
		let value = try JSONDecoder().decode(JSONValue.self, from: data)
		if case .bool(let b)? = value["detect_indent"] { detectIndent = b }
		if case .bool(let b)? = value["auto_save"] { autoSave = b }
		if case .bool(let b)? = value["wrap_lines"] { wrapLines = b }
		if case .bool(let b)? = value["sticky_lines"] { stickyLines = b }
		if case .string(let f)? = value["font_family"], !f.isEmpty { fontFamily = f }
		if case .number(let n)? = value["font_size"], n > 0 { fontSize = n }
		if case .bool(let b)? = value["auto_check_updates"] { autoCheckUpdates = b }
		if case .bool(let b)? = value["auto_download_updates"] { autoDownloadUpdates = b }
		if case .string(let l)? = value["language"], !l.isEmpty { language = l }
		if case .object(let sections)? = value["format"] {
			for (section, props) in sections {
				guard case .object(let p) = props else { continue }
				format[section] = p.compactMapValues { v in
					switch v {
					case .string(let s): s
					case .number(let n): n == n.rounded() ? String(Int(n)) : String(n)
					case .bool(let b): b ? "true" : "false"
					default: nil
					}
				}
			}
		}
	}

	public static func load(_ url: URL) -> SettingsFile? {
		guard let data = try? Data(contentsOf: url) else { return nil }
		return try? SettingsFile(json: data)
	}

	/// Written when the user opens settings for the first time.
	public static let template = """
	{
	  "detect_indent": true,
	  "format": {
	    "*": {
	      "end_of_line": "lf",
	      "charset": "utf-8",
	      "insert_final_newline": true,
	      "trim_trailing_whitespace": "modified"
	    },
	    "php": { "preset": "psr12" },
	    "go": { "tab_width": 4 },
	    "javascript": { "indent_size": 2 }
	  }
	}

	"""

	public enum UpdateError: Error { case unreadable }

	/// settings.json `data` with one value changed and everything else kept (keys come out
	/// sorted). `section` nil is a top-level key, otherwise a section of "format"; nil `value`
	/// removes the key and a section left empty. A file that is not a JSON object is not
	/// overwritten (throws).
	public static func updating(_ data: Data?, section: String?, key: String, value: JSONValue?) throws -> Data {
		var root: [String: JSONValue] = [:]
		if let data, !data.allSatisfy({ $0 == 0x20 || $0 == 0x0A || $0 == 0x0D || $0 == 0x09 }) {
			guard case .object(let object)? = try? JSONDecoder().decode(JSONValue.self, from: data) else { throw UpdateError.unreadable }
			root = object
		}
		if let section {
			guard case .object(var format) = root["format"] ?? .object([:]) else { throw UpdateError.unreadable }
			guard case .object(var props) = format[section] ?? .object([:]) else { throw UpdateError.unreadable }
			props[key] = value
			format[section] = props.isEmpty ? nil : .object(props)
			root["format"] = format.isEmpty ? nil : .object(format)
		} else {
			root[key] = value
		}
		let encoder = JSONEncoder()
		encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
		return try encoder.encode(JSONValue.object(root)) + Data("\n".utf8)
	}

	public static var userURL: URL {
		FileManager.default.homeDirectoryForCurrentUser
			.appendingPathComponent("Library/Application Support/MinorIDE/settings.json")
	}
}

/// Where each effective value came from, for the status bar and debugging.
public enum FormatSource: String, Sendable {
	case defaults, user, project, editorConfig, detected, file
}

public struct ResolvedFormat: Sendable {
	public var settings: FormatSettings
	public var indentSource: FormatSource
	public var lineEndingSource: FormatSource
}

/// Precedence, lowest to highest: language defaults (PSR-12, gofmt, …) < user settings <
/// project settings < .editorconfig. Then, for existing files: the file's own line ending is kept,
/// and its indentation is used when detection is on and neither the project nor .editorconfig fixes it.
public enum FormatResolver {
	public static func resolve(
		path: String,
		user: SettingsFile?,
		project: SettingsFile?,
		editorConfig: [String: String],
		detected: DetectedFormat?
	) -> ResolvedFormat {
		let language = Language.id(forFile: path)
		let fileName = (path as NSString).lastPathComponent
		let preset = project?.format[language]?["preset"] ?? user?.format[language]?["preset"]

		var s = FormatSettings()
		var indentSource = FormatSource.defaults
		var eolSource = FormatSource.defaults
		func layer(_ props: [String: String]?, _ source: FormatSource) {
			guard let props, !props.isEmpty else { return }
			s.apply(props)
			if props["indent_style"] != nil || props["indent_size"] != nil { indentSource = source }
			if props["end_of_line"] != nil { eolSource = source }
		}
		s.apply(FormatDefaults.properties(language: language, fileName: fileName, preset: preset))
		layer(user?.format["*"], .user)
		layer(user?.format[language], .user)
		layer(project?.format["*"], .project)
		layer(project?.format[language], .project)
		layer(editorConfig, .editorConfig)

		if let detected {
			if let eol = detected.lineEnding {
				s.lineEnding = eol
				eolSource = .file
			}
			let detect = project?.detectIndent ?? user?.detectIndent ?? true
			if detect, indentSource != .project, indentSource != .editorConfig, let style = detected.indentStyle {
				s.indentStyle = style
				if let size = detected.indentSize { s.indentSize = size }
				indentSource = .detected
			}
		}
		return ResolvedFormat(settings: s, indentSource: indentSource, lineEndingSource: eolSource)
	}
}
