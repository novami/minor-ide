/// What the editor needs to know about a language besides its tokens: comments, brackets,
/// quotes and indentation hints.
public struct SyntaxLanguage: Sendable {
	public enum Comment: Sendable, Equatable {
		case line(String)
		case block(String, String)
	}

	public let name: String
	public let lexer: any Lexer
	public let comment: Comment
	/// Pairs typed together and used for wrapping a selection: brackets, then quotes.
	public let brackets: [(open: UInt8, close: UInt8)]
	public let quotes: [UInt8]
	/// Enter after ":" adds a level (NEON, YAML).
	public let indentAfterColon: Bool
	/// Comment style at a lexer state, for languages embedding others (HTML parts of PHP).
	let commentAtState: (@Sendable (LexState) -> Comment)?

	public func comment(at state: LexState) -> Comment {
		commentAtState?(state) ?? comment
	}

	static let codeBrackets: [(open: UInt8, close: UInt8)] = [(0x28, 0x29), (0x5B, 0x5D), (0x7B, 0x7D)]

	public static let go = SyntaxLanguage(name: "Go", lexer: GoLexer(), comment: .line("//"), brackets: codeBrackets,
	                                quotes: [0x22, 0x27, 0x60], indentAfterColon: false, commentAtState: nil)
	public static let json = SyntaxLanguage(name: "JSON", lexer: JSONLexer(), comment: .line("//"), brackets: codeBrackets,
	                                  quotes: [0x22], indentAfterColon: false, commentAtState: nil)
	public static let php = SyntaxLanguage(name: "PHP", lexer: PHPLexer(), comment: .line("//"), brackets: codeBrackets,
	                                 quotes: [0x22, 0x27], indentAfterColon: false, commentAtState: { state in
		// HTML around the PHP code (html, comment, tag, attribute modes) takes HTML comments.
		let htmlModes: Set<UInt8> = [PHPLexer.Mode.html.rawValue, PHPLexer.Mode.htmlComment.rawValue, PHPLexer.Mode.htmlTag.rawValue]
		return htmlModes.contains(state.mode) ? .block("<!--", "-->") : .line("//")
	})
	public static let sql = SyntaxLanguage(name: "SQL", lexer: SQLLexer(), comment: .line("--"), brackets: [(0x28, 0x29)],
	                                 quotes: [0x27, 0x22, 0x60], indentAfterColon: false, commentAtState: nil)
	public static let neon = SyntaxLanguage(name: "NEON", lexer: NEONLexer(), comment: .line("#"), brackets: codeBrackets,
	                                  quotes: [0x22, 0x27], indentAfterColon: true, commentAtState: nil)
	public static let javascript = SyntaxLanguage(name: "JavaScript", lexer: JSLexer(), comment: .line("//"), brackets: codeBrackets,
	                                              quotes: [0x22, 0x27, 0x60], indentAfterColon: false, commentAtState: nil)
	public static let css = SyntaxLanguage(name: "CSS", lexer: CSSLexer(), comment: .block("/*", "*/"), brackets: codeBrackets,
	                                       quotes: [0x22, 0x27], indentAfterColon: false, commentAtState: nil)
	public static let html = SyntaxLanguage(name: "HTML", lexer: LatteLexer(latte: false), comment: .block("<!--", "-->"), brackets: codeBrackets,
	                                        quotes: [0x22, 0x27], indentAfterColon: false, commentAtState: nil)
	public static let yaml = SyntaxLanguage(name: "YAML", lexer: NEONLexer(), comment: .line("#"), brackets: codeBrackets,
	                                        quotes: [0x22, 0x27], indentAfterColon: true, commentAtState: nil)
	public static let shell = SyntaxLanguage(name: "Shell", lexer: ShellLexer(), comment: .line("#"), brackets: codeBrackets,
	                                         quotes: [0x22, 0x27, 0x60], indentAfterColon: false, commentAtState: nil)
	public static let dockerfile = SyntaxLanguage(name: "Dockerfile", lexer: ShellLexer(.dockerfile), comment: .line("#"), brackets: codeBrackets,
	                                              quotes: [0x22, 0x27], indentAfterColon: false, commentAtState: nil)
	public static let makefile = SyntaxLanguage(name: "Makefile", lexer: ShellLexer(.makefile), comment: .line("#"), brackets: codeBrackets,
	                                            quotes: [0x22, 0x27], indentAfterColon: true, commentAtState: nil)
	public static let env = SyntaxLanguage(name: "Environment", lexer: ShellLexer(.env), comment: .line("#"), brackets: [],
	                                       quotes: [0x22, 0x27], indentAfterColon: false, commentAtState: nil)
	public static let markdown = SyntaxLanguage(name: "Markdown", lexer: MarkdownLexer(), comment: .block("<!--", "-->"), brackets: codeBrackets,
	                                            quotes: [], indentAfterColon: false, commentAtState: nil)
	public static let latte = SyntaxLanguage(name: "Latte", lexer: LatteLexer(), comment: .block("{*", "*}"), brackets: codeBrackets,
	                                   quotes: [0x22, 0x27], indentAfterColon: false, commentAtState: nil)
}

/// Language of a file, chosen by extension (and a few file names).
public enum Languages {
	public static func language(forPath path: String) -> SyntaxLanguage? {
		let name = path.split(separator: "/").last.map(String.init) ?? path
		let parts = name.split(separator: ".")
		let ext = parts.count > 1 ? (parts.last ?? "").lowercased() : ""
		switch ext {
		case "go": return .go
		case "json", "jsonc", "code-workspace": return .json
		case "php", "phtml", "phpt", "inc": return .php
		case "sql": return .sql
		case "neon": return .neon
		case "latte": return .latte
		case "js", "mjs", "cjs", "ts", "mts", "jsx", "tsx": return .javascript
		case "css", "scss": return .css
		case "html", "htm", "xml", "svg", "xsd", "xsl", "plist", "xlf": return .html
		case "yaml", "yml": return .yaml
		case "sh", "bash", "zsh": return .shell
		case "mk": return .makefile
		case "md", "markdown": return .markdown
		case "env" where name.hasPrefix(".env"): return .env
		default:
			if name == "composer.lock" { return .json }
			if name == "Dockerfile" || name.hasPrefix("Dockerfile.") || name.hasSuffix(".dockerfile") { return .dockerfile }
			if name == "Makefile" || name == "makefile" || name == "GNUmakefile" { return .makefile }
			if name == ".env" || name.hasPrefix(".env.") { return .env }
			return nil
		}
	}

	public static func lexer(forPath path: String) -> (any Lexer)? {
		language(forPath: path)?.lexer
	}
}
