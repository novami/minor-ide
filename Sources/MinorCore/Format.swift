import Foundation

public enum IndentStyle: String, Sendable, CaseIterable {
	case tab, space
}

public enum LineEnding: String, Sendable, CaseIterable {
	case lf, crlf, cr

	public var string: String {
		switch self {
		case .lf: "\n"
		case .crlf: "\r\n"
		case .cr: "\r"
		}
	}

	public var label: String { rawValue.uppercased() }
}

/// File encodings. The first five are EditorConfig values; the last two cover legacy Czech projects.
public enum Charset: String, Sendable, CaseIterable {
	case utf8 = "utf-8"
	case utf8bom = "utf-8-bom"
	case latin1
	case utf16be = "utf-16be"
	case utf16le = "utf-16le"
	case windows1250 = "windows-1250"
	case iso88592 = "iso-8859-2"

	public var encoding: String.Encoding {
		switch self {
		case .utf8, .utf8bom: .utf8
		case .latin1: .isoLatin1
		case .utf16be: .utf16BigEndian
		case .utf16le: .utf16LittleEndian
		case .windows1250: .windowsCP1250
		case .iso88592: .isoLatin2
		}
	}
}

public enum TrimMode: String, Sendable {
	case none
	case modifiedLines // default: legacy files do not get whole-file whitespace diffs
	case all           // EditorConfig `trim_trailing_whitespace = true`
}

/// Effective formatting rules for one file. Property names follow EditorConfig, so the same
/// keys work in `.editorconfig`, the user's settings.json and a project's .minoride/settings.json.
public struct FormatSettings: Equatable, Sendable {
	public var indentStyle: IndentStyle = .space
	public var indentSize = 4
	public var tabWidth = 4
	public var lineEnding: LineEnding = .lf
	public var charset: Charset = .utf8
	public var insertFinalNewline = true
	public var trimTrailingWhitespace: TrimMode = .modifiedLines
	public var maxLineLength: Int?
	/// Run the language's formatter when the file is saved (`format_on_save`).
	public var formatOnSave = false

	public init() {}

	/// One indentation level as text.
	public var indentUnit: String {
		indentStyle == .tab ? "\t" : String(repeating: " ", count: indentSize)
	}

	/// Applies EditorConfig-style properties. Unknown keys and invalid values are ignored,
	/// `unset` restores the built-in value.
	public mutating func apply(_ properties: [String: String]) {
		let base = FormatSettings()
		// EditorConfig: tab_width defaults to indent_size when only indent_size is given.
		var properties = properties
		if properties["tab_width"] == nil, let size = properties["indent_size"], Int(size) != nil {
			properties["tab_width"] = size
		}
		// tab_width first: indent_size = tab refers to it
		var keys = Array(properties.keys)
		if let i = keys.firstIndex(of: "tab_width") { keys.swapAt(0, i) }
		for key in keys {
			let value = properties[key]!.lowercased().trimmingCharacters(in: .whitespaces)
			let unset = value == "unset"
			switch key {
			case "indent_style":
				indentStyle = unset ? base.indentStyle : IndentStyle(rawValue: value) ?? indentStyle
			case "indent_size":
				if unset { indentSize = base.indentSize }
				else if value == "tab" { indentSize = tabWidth }
				else if let n = Int(value), (1...16).contains(n) { indentSize = n }
			case "tab_width":
				if unset { tabWidth = base.tabWidth }
				else if let n = Int(value), (1...16).contains(n) { tabWidth = n }
			case "end_of_line":
				lineEnding = unset ? base.lineEnding : LineEnding(rawValue: value) ?? lineEnding
			case "charset":
				charset = unset ? base.charset : Charset(rawValue: value) ?? charset
			case "insert_final_newline":
				insertFinalNewline = unset ? base.insertFinalNewline : value == "true" ? true : value == "false" ? false : insertFinalNewline
			case "trim_trailing_whitespace":
				switch value {
				case "true": trimTrailingWhitespace = .all
				case "false": trimTrailingWhitespace = .none
				case "modified": trimTrailingWhitespace = .modifiedLines
				case "unset": trimTrailingWhitespace = base.trimTrailingWhitespace
				default: break
				}
			case "format_on_save":
				formatOnSave = unset ? base.formatOnSave : value == "true" ? true : value == "false" ? false : formatOnSave
			case "max_line_length":
				maxLineLength = value == "off" || unset ? nil : Int(value) ?? maxLineLength
			default:
				break
			}
		}
	}
}

/// Language ids used for per-language defaults and settings sections.
public enum Language {
	public static func id(forFile path: String) -> String {
		let name = (path as NSString).lastPathComponent.lowercased()
		switch name {
		case "makefile", "gnumakefile": return "makefile"
		case "dockerfile": return "dockerfile"
		case "composer.json", "composer.lock": return "json"
		case ".env": return "dotenv"
		default: break
		}
		if name.hasPrefix(".env.") { return "dotenv" }
		if name.hasSuffix(".neon.dist") { return "neon" }
		switch (name as NSString).pathExtension {
		case "php", "phtml", "phpt", "inc": return "php"
		case "go": return "go"
		case "latte": return "latte"
		case "neon": return "neon"
		case "js", "mjs", "cjs", "jsx": return "javascript"
		case "ts", "tsx", "mts": return "typescript"
		case "vue": return "vue"
		case "json", "jsonc": return "json"
		case "css": return "css"
		case "scss", "sass", "less": return "scss"
		case "html", "htm": return "html"
		case "xml", "xsd", "xsl", "svg": return "xml"
		case "yml", "yaml": return "yaml"
		case "md", "markdown": return "markdown"
		case "sql": return "sql"
		case "sh", "bash", "zsh": return "shell"
		case "bat", "cmd": return "batch"
		case "mk": return "makefile"
		default: return "text"
		}
	}
}

/// Built-in defaults follow each ecosystem's standard.
public enum FormatDefaults {
	/// Named presets selectable per language with `"preset"` in settings.json.
	public static let presets: [String: [String: [String: String]]] = [
		"php": [
			"psr12": ["indent_style": "space", "indent_size": "4", "max_line_length": "120"], // PSR-12 (and PER-CS)
			"nette": ["indent_style": "tab", "tab_width": "4", "max_line_length": "120"],    // Nette Coding Standard
		],
	]

	public static func properties(language: String, fileName: String, preset: String? = nil) -> [String: String] {
		// Shared baseline (PSR-12 §2: LF, UTF-8 without BOM, final newline, no trailing whitespace).
		var p: [String: String] = [
			"indent_style": "space", "indent_size": "4", "tab_width": "4", "end_of_line": "lf",
			"charset": "utf-8", "insert_final_newline": "true",
		]
		let languageDefaults: [String: String]
		switch language {
		case "php": languageDefaults = presets["php"]![preset ?? "psr12"] ?? presets["php"]!["psr12"]!
		case "go": languageDefaults = ["indent_style": "tab", "tab_width": "4", "format_on_save": "true"] // gofmt
		case "latte", "neon": languageDefaults = ["indent_style": "tab", "tab_width": "4"] // Nette conventions
		case "javascript", "typescript", "vue", "css", "scss", "html", "yaml":
			languageDefaults = ["indent_size": "2"] // Prettier / YAML convention; YAML forbids tabs
		case "json":
			// composer writes 4 spaces; package.json and most tools use 2
			languageDefaults = ["indent_size": fileName.lowercased().hasPrefix("composer.") ? "4" : "2"]
		case "markdown": languageDefaults = ["indent_size": "2", "trim_trailing_whitespace": "false"] // two trailing spaces = line break
		case "makefile": languageDefaults = ["indent_style": "tab", "tab_width": "8"] // recipes must start with a tab
		case "batch": languageDefaults = ["end_of_line": "crlf"]
		default: languageDefaults = [:]
		}
		p.merge(languageDefaults) { $1 }
		return p
	}
}
