import Foundation

/// LSP glob pattern: `*`, `?`, `**`, `{a,b}`, `[abc]`, `[!abc]`. Matched against a whole path.
nonisolated public struct LSPGlob: Sendable {
	private let regex: NSRegularExpression?

	public init(_ pattern: String) {
		regex = try? NSRegularExpression(pattern: "^" + Self.translate(Array(pattern)) + "$")
	}

	public func matches(_ path: String) -> Bool {
		guard let regex else { return false }
		return regex.firstMatch(in: path, range: NSRange(path.startIndex..., in: path)) != nil
	}

	private static func translate(_ p: [Character]) -> String {
		var out = ""
		var i = 0
		var braces = 0
		while i < p.count {
			let c = p[i]
			switch c {
			case "*":
				if i + 1 < p.count && p[i + 1] == "*" {
					if i + 2 < p.count && p[i + 2] == "/" {
						out += "(?:.*/)?"
						i += 3
					} else {
						out += ".*"
						i += 2
					}
					continue
				}
				out += "[^/]*"
			case "?":
				out += "[^/]"
			case "{":
				braces += 1
				out += "(?:"
			case "}" where braces > 0:
				braces -= 1
				out += ")"
			case "," where braces > 0:
				out += "|"
			case "[":
				if let close = p[(i + 1)...].firstIndex(of: "]"), close > i + 1 {
					var body = String(p[(i + 1)..<close])
					if body.hasPrefix("!") { body = "^" + body.dropFirst() }
					out += "[" + body.replacingOccurrences(of: "\\", with: "\\\\") + "]"
					i = close + 1
					continue
				}
				out += "\\["
			default:
				out += NSRegularExpression.escapedPattern(for: String(c))
			}
			i += 1
		}
		return out + String(repeating: ")", count: braces)
	}
}
