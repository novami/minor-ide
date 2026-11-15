/// Lexer for a file, chosen by extension (and a few file names).
public enum Languages {
	public static func lexer(forPath path: String) -> (any Lexer)? {
		let name = path.split(separator: "/").last.map(String.init) ?? path
		let ext = name.split(separator: ".").count > 1 ? String(name.split(separator: ".").last!).lowercased() : ""
		switch ext {
		case "go": return GoLexer()
		case "php", "phtml", "phpt", "inc": return PHPLexer()
		case "sql": return SQLLexer()
		case "neon": return NEONLexer()
		case "json", "jsonc", "code-workspace": return JSONLexer()
		default:
			if name == "composer.lock" { return JSONLexer() }
			return nil
		}
	}
}
