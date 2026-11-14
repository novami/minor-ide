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

	public init() {}

	public init(json data: Data) throws {
		let value = try JSONDecoder().decode(JSONValue.self, from: data)
		if case .bool(let b)? = value["detect_indent"] { detectIndent = b }
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
