import Foundation

/// One parsed `.editorconfig` file (https://spec.editorconfig.org).
nonisolated public struct EditorConfigFile: Sendable {
	public struct Section: Sendable {
		public let glob: String
		public let properties: [String: String]
		let regex: NSRegularExpression?
	}

	public var root = false
	public var sections: [Section] = []

	public init(parsing text: String) {
		var glob: String?
		var props: [String: String] = [:]
		func flush() {
			if let g = glob { sections.append(Section(glob: g, properties: props, regex: EditorConfigFile.regex(for: g))) }
		}
		for raw in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
			let line = raw.trimmingCharacters(in: .whitespaces)
			if line.isEmpty || line.hasPrefix("#") || line.hasPrefix(";") { continue }
			if line.hasPrefix("["), line.hasSuffix("]") {
				flush()
				glob = String(line.dropFirst().dropLast())
				props = [:]
				continue
			}
			guard let eq = line.firstIndex(of: "=") else { continue }
			let key = line[..<eq].trimmingCharacters(in: .whitespaces).lowercased()
			let value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
			if glob == nil {
				if key == "root" { root = value.lowercased() == "true" }
			} else {
				props[key] = value
			}
		}
		flush()
	}

	/// Properties for a path relative to this file's directory (forward slashes).
	public func properties(forRelativePath path: String) -> [String: String] {
		var result: [String: String] = [:]
		let range = NSRange(path.startIndex..., in: path)
		for s in sections where s.regex?.firstMatch(in: path, range: range) != nil {
			result.merge(s.properties) { $1 }
		}
		return result
	}

	/// Converts an EditorConfig glob to an anchored regex. Globs without "/" match at any depth.
	static func regex(for glob: String) -> NSRegularExpression? {
		var g = glob
		let anchored = g.contains("/")
		if g.hasPrefix("/") { g.removeFirst() }
		var out = anchored ? "^" : "^(?:.*/)?"
		let chars = Array(g)
		var i = 0
		var braceDepth = 0
		while i < chars.count {
			let c = chars[i]
			switch c {
			case "\\":
				i += 1
				if i < chars.count { out += NSRegularExpression.escapedPattern(for: String(chars[i])) }
			case "*":
				if i + 1 < chars.count, chars[i + 1] == "*" {
					out += ".*"
					i += 1
				} else {
					out += "[^/]*"
				}
			case "?": out += "[^/]"
			case "[":
				if let close = chars[(i + 1)...].firstIndex(of: "]") {
					var body = String(chars[(i + 1)..<close])
					if body.hasPrefix("!") { body = "^" + body.dropFirst() }
					out += "[" + body.replacingOccurrences(of: "/", with: "") + "]"
					i = close
				} else {
					out += "\\["
				}
			case "{":
				if let close = chars[(i + 1)...].firstIndex(of: "}"),
				   let range = numericRange(String(chars[(i + 1)..<close])) {
					out += "(?:" + range.map(String.init).joined(separator: "|") + ")"
					i = close
				} else if chars[(i + 1)...].contains("}") {
					out += "(?:"
					braceDepth += 1
				} else {
					out += "\\{"
				}
			case "}" where braceDepth > 0:
				out += ")"
				braceDepth -= 1
			case "," where braceDepth > 0:
				out += "|"
			default:
				out += NSRegularExpression.escapedPattern(for: String(c))
			}
			i += 1
		}
		return try? NSRegularExpression(pattern: out + "$")
	}

	/// `{1..3}` → 1, 2, 3 (small ranges only).
	private static func numericRange(_ s: String) -> ClosedRange<Int>? {
		let parts = s.components(separatedBy: "..")
		guard parts.count == 2, let a = Int(parts[0]), let b = Int(parts[1]), a <= b, b - a <= 1000 else { return nil }
		return a...b
	}
}

nonisolated public enum EditorConfig {
	/// Collects properties for a file from `.editorconfig` files in its directory and the parents,
	/// stopping at `root = true`. Closer files win.
	public static func properties(forFile path: String, read: (String) -> String? = { try? String(contentsOfFile: $0, encoding: .utf8) }) -> [String: String] {
		var files: [(dir: String, file: EditorConfigFile)] = []
		var dir = (path as NSString).deletingLastPathComponent
		while true {
			if let text = read((dir as NSString).appendingPathComponent(".editorconfig")) {
				let f = EditorConfigFile(parsing: text)
				files.append((dir, f))
				if f.root { break }
			}
			let parent = (dir as NSString).deletingLastPathComponent
			if parent == dir || dir.isEmpty { break }
			dir = parent
		}
		var result: [String: String] = [:]
		for (dir, file) in files.reversed() {
			let prefix = dir.hasSuffix("/") ? dir : dir + "/"
			guard path.hasPrefix(prefix) else { continue }
			result.merge(file.properties(forRelativePath: String(path.dropFirst(prefix.count)))) { $1 }
		}
		return result
	}
}
