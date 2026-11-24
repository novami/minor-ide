import Foundation

/// Patterns of one `.gitignore` file (or `.git/info/exclude`), matched against paths relative
/// to the folder of the file. Supports `#` comments, `!` negation, `\` escapes, trailing `/`
/// (folders only), anchoring by a `/` at the start or in the middle, `*`, `?`, `[…]` and `**`.
nonisolated public struct GitIgnore: Sendable {
	struct Rule: Sendable {
		let pattern: [UInt8]
		let negate: Bool
		let dirOnly: Bool
		/// Contains a slash: matched against the whole relative path, else against the name.
		let anchored: Bool
	}

	let rules: [Rule]

	public init(_ text: String) {
		var rules: [Rule] = []
		for raw in text.split(omittingEmptySubsequences: true, whereSeparator: { $0 == "\n" || $0 == "\r" }) {
			var line = Array(raw.utf8)
			guard let first = line.first, first != UInt8(ascii: "#") else { continue }
			// Trailing spaces are dropped unless escaped.
			while line.last == 0x20, !(line.count >= 2 && line[line.count - 2] == UInt8(ascii: "\\")) { line.removeLast() }
			var negate = false
			if line.first == UInt8(ascii: "!") { negate = true; line.removeFirst() }
			else if line.first == UInt8(ascii: "\\") { line.removeFirst() }
			var dirOnly = false
			if line.last == UInt8(ascii: "/") { dirOnly = true; line.removeLast() }
			guard !line.isEmpty else { continue }
			let anchored = line.contains(UInt8(ascii: "/"))
			if line.first == UInt8(ascii: "/") { line.removeFirst() }
			rules.append(Rule(pattern: line, negate: negate, dirOnly: dirOnly, anchored: anchored))
		}
		self.rules = rules
	}

	public var isEmpty: Bool { rules.isEmpty }

	/// true = ignored, false = explicitly not ignored (`!`), nil = no pattern matches.
	public func match(_ relativePath: String, isDirectory: Bool) -> Bool? {
		let path = Array(relativePath.utf8)
		let name = path.lastIndex(of: UInt8(ascii: "/")).map { Array(path[($0 + 1)...]) } ?? path
		for rule in rules.reversed() {
			if rule.dirOnly && !isDirectory { continue }
			let subject = rule.anchored ? path : name
			if Self.glob(rule.pattern[...], subject[...]) { return !rule.negate }
		}
		return nil
	}

	/// Glob match of a whole string; `*` and `?` stop at `/`, `**` crosses folders.
	static func glob(_ p: ArraySlice<UInt8>, _ s: ArraySlice<UInt8>) -> Bool {
		let slash = UInt8(ascii: "/"), star = UInt8(ascii: "*")
		var p = p, s = s
		while let c = p.first {
			if c == star {
				if p.dropFirst().first == star {
					// `**/` matches zero or more folders, a trailing `**` everything.
					var rest = p.dropFirst(2)
					if rest.isEmpty { return true }
					if rest.first == slash { rest = rest.dropFirst() }
					var t = s
					while true {
						if glob(rest, t) { return true }
						guard let i = t.firstIndex(of: slash) else { return false }
						t = t[(i + 1)...]
					}
				}
				let rest = p.dropFirst()
				var t = s
				while true {
					if glob(rest, t) { return true }
					guard let f = t.first, f != slash else { return false }
					t = t.dropFirst()
				}
			}
			guard let f = s.first else { return false }
			if c == UInt8(ascii: "?") {
				guard f != slash else { return false }
			} else if c == UInt8(ascii: "[") {
				guard let (ok, next) = bracket(p, f), ok, f != slash else { return false }
				p = next
				s = s.dropFirst()
				continue
			} else {
				var lit = c
				if c == UInt8(ascii: "\\"), let e = p.dropFirst().first { lit = e; p = p.dropFirst() }
				guard lit == f else { return false }
			}
			p = p.dropFirst()
			s = s.dropFirst()
		}
		return s.isEmpty
	}

	/// `[abc]`, `[a-z]`, `[!x]`: whether `c` matches, and the pattern after the class.
	private static func bracket(_ p: ArraySlice<UInt8>, _ c: UInt8) -> (Bool, ArraySlice<UInt8>)? {
		var i = p.index(after: p.startIndex)
		var negate = false
		if i < p.endIndex, p[i] == UInt8(ascii: "!") || p[i] == UInt8(ascii: "^") { negate = true; i += 1 }
		var matched = false, first = true
		while i < p.endIndex, p[i] != UInt8(ascii: "]") || first {
			first = false
			if i + 2 < p.endIndex, p[i + 1] == UInt8(ascii: "-"), p[i + 2] != UInt8(ascii: "]") {
				if p[i] <= c && c <= p[i + 2] { matched = true }
				i += 3
			} else {
				if p[i] == c { matched = true }
				i += 1
			}
		}
		guard i < p.endIndex else { return nil }
		return (matched != negate, p[(i + 1)...])
	}
}

/// The `.gitignore` files of a tree, read on demand and cached per folder. Deeper files win
/// over higher ones; `.git/info/exclude` of the root is the lowest priority.
nonisolated public final class GitIgnoreSet: @unchecked Sendable {
	public let root: URL
	private let lock = NSLock()
	private var files: [String: GitIgnore] = [:] // folder relative path ("" = root) → patterns
	private let exclude: GitIgnore?

	public init(root: URL) {
		self.root = root.standardizedFileURL
		let info = GitHead.gitDirectory(for: self.root).map { $0.appendingPathComponent("info/exclude") }
		exclude = info.flatMap { try? String(contentsOf: $0, encoding: .utf8) }.map(GitIgnore.init)
	}

	/// Forgets cached files (a `.gitignore` changed).
	public func reset() { lock.withLock { files = [:] } }

	private func patterns(in folder: String) -> GitIgnore {
		if let known = lock.withLock({ files[folder] }) { return known }
		let url = folder.isEmpty ? root : root.appendingPathComponent(folder)
		let text = (try? String(contentsOf: url.appendingPathComponent(".gitignore"), encoding: .utf8)) ?? ""
		let parsed = GitIgnore(text)
		lock.withLock { files[folder] = parsed }
		return parsed
	}

	/// Whether `path` itself matches, ignoring its parents (the walk stops at ignored folders).
	public func matches(_ path: String, isDirectory: Bool) -> Bool {
		var folder = path
		while true {
			let cut = folder.lastIndex(of: "/")
			folder = cut.map { String(folder[..<$0]) } ?? ""
			let rel = folder.isEmpty ? path : String(path.dropFirst(folder.count + 1))
			if let result = patterns(in: folder).match(rel, isDirectory: isDirectory) { return result }
			if folder.isEmpty { break }
		}
		return exclude?.match(path, isDirectory: isDirectory) ?? false
	}

	/// Whether `path` or one of its folders is ignored.
	public func isIgnored(_ path: String, isDirectory: Bool) -> Bool {
		let parts = path.split(separator: "/")
		var prefix = ""
		for (i, part) in parts.enumerated() {
			prefix = prefix.isEmpty ? String(part) : prefix + "/" + part
			let last = i == parts.count - 1
			if matches(prefix, isDirectory: last ? isDirectory : true) { return true }
		}
		return false
	}
}
