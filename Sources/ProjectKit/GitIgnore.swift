import Foundation

/// One pattern of a .gitignore file.
struct IgnoreRule {
	var pattern: [UInt8]
	var negate = false
	var dirOnly = false
	/// Contains a slash: matched against the whole relative path.
	var anchored = false
}

/// The patterns of one .gitignore (or .git/info/exclude).
struct IgnoreFile {
	var rules: [IgnoreRule] = []

	init(_ text: String) {
		for var line in text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }).map({ Array($0.utf8) }) {
			if line.isEmpty || line[0] == UInt8(ascii: "#") { continue }
			while line.last == UInt8(ascii: " "), !(line.count >= 2 && line[line.count - 2] == UInt8(ascii: "\\")) { line.removeLast() }
			var rule = IgnoreRule(pattern: [])
			if line.first == UInt8(ascii: "!") {
				rule.negate = true
				line.removeFirst()
			} else if line.first == UInt8(ascii: "\\") {
				line.removeFirst()
			}
			if line.last == UInt8(ascii: "/") {
				rule.dirOnly = true
				line.removeLast()
			}
			if line.isEmpty { continue }
			rule.anchored = line.contains(UInt8(ascii: "/"))
			if line.first == UInt8(ascii: "/") { line.removeFirst() }
			rule.pattern = line
			rules.append(rule)
		}
	}

	/// (ignored, decided): the last matching pattern decides.
	func match(_ rel: String, isDir: Bool) -> (ignored: Bool, decided: Bool) {
		let path = Array(rel.utf8)
		let name = path.lastIndex(of: UInt8(ascii: "/")).map { Array(path[($0 + 1)...]) } ?? path
		for rule in rules.reversed() {
			if rule.dirOnly && !isDir { continue }
			if Glob.match(rule.pattern[...], (rule.anchored ? path : name)[...]) { return (!rule.negate, true) }
		}
		return (false, false)
	}
}

/// Shell-style matching of a whole string: `*` and `?` stop at `/`, `**` crosses folders.
enum Glob {
	static func match(_ pattern: ArraySlice<UInt8>, _ string: ArraySlice<UInt8>) -> Bool {
		var p = pattern, s = string
		let slash = UInt8(ascii: "/"), star = UInt8(ascii: "*")
		while let c = p.first {
			if c == star, p.count > 1, p[p.startIndex + 1] == star {
				var rest = p.dropFirst(2)
				if rest.isEmpty { return true }
				if rest.first == slash { rest = rest.dropFirst() }
				var t = s
				while true {
					if match(rest, t) { return true }
					guard let i = t.firstIndex(of: slash) else { return false }
					t = t[(i + 1)...]
				}
			}
			if c == star {
				let rest = p.dropFirst()
				var t = s
				while true {
					if match(rest, t) { return true }
					if t.isEmpty || t.first == slash { return false }
					t = t.dropFirst()
				}
			}
			guard let sc = s.first else { return false }
			switch c {
			case UInt8(ascii: "?"):
				if sc == slash { return false }
			case UInt8(ascii: "["):
				guard let (ok, next) = bracket(p, sc), ok, sc != slash else { return false }
				p = next
				s = s.dropFirst()
				continue
			case UInt8(ascii: "\\"):
				if p.count > 1 { p = p.dropFirst() }
				if p.first != sc { return false }
			default:
				if c != sc { return false }
			}
			p = p.dropFirst()
			s = s.dropFirst()
		}
		return s.isEmpty
	}

	/// Matches `c` against the bracket expression at the start of `p`; nil when it is not closed.
	private static func bracket(_ p: ArraySlice<UInt8>, _ c: UInt8) -> (Bool, ArraySlice<UInt8>)? {
		var i = p.startIndex + 1
		var negate = false, matched = false, first = true
		if i < p.endIndex, p[i] == UInt8(ascii: "!") || p[i] == UInt8(ascii: "^") {
			negate = true
			i += 1
		}
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

/// Reads .gitignore files on demand; deeper files win over higher ones and
/// `.git/info/exclude` of the repository has the lowest priority.
final class IgnoreSet: @unchecked Sendable {
	private let root: URL
	private let lock = NSLock()
	private var files: [String: IgnoreFile] = [:]
	private var exclude = IgnoreFile("")

	init(root: URL) {
		self.root = root
		if let git = Self.gitDir(root), let data = try? Data(contentsOf: git.appendingPathComponent("info/exclude")) {
			exclude = IgnoreFile(String(decoding: data, as: UTF8.self))
		}
	}

	/// The nearest .git folder at or above `dir` (nil outside a repository).
	static func gitDir(_ start: URL) -> URL? {
		var dir = start
		while true {
			let git = dir.appendingPathComponent(".git")
			var isDir: ObjCBool = false
			if FileManager.default.fileExists(atPath: git.path, isDirectory: &isDir) {
				if isDir.boolValue { return git }
				guard let text = try? String(contentsOf: git, encoding: .utf8), text.hasPrefix("gitdir:") else { return nil }
				let path = text.dropFirst(7).split(separator: "\n").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
				return path.hasPrefix("/") ? URL(fileURLWithPath: path) : URL(fileURLWithPath: path, relativeTo: dir).standardized
			}
			if dir.path == "/" || dir.path.isEmpty { return nil }
			dir = dir.deletingLastPathComponent()
		}
	}

	private func patterns(_ folder: String) -> IgnoreFile {
		lock.lock()
		let cached = files[folder]
		lock.unlock()
		if let cached { return cached }
		let url = folder.isEmpty ? root : root.appendingPathComponent(folder)
		let data = (try? Data(contentsOf: url.appendingPathComponent(".gitignore"))) ?? Data()
		let file = IgnoreFile(String(decoding: data, as: UTF8.self))
		lock.lock()
		files[folder] = file
		lock.unlock()
		return file
	}

	/// Whether `rel` itself is ignored (its folders are checked by the walk).
	func matches(_ rel: String, isDir: Bool) -> Bool {
		var folder = rel
		while true {
			if let i = folder.lastIndex(of: "/") { folder = String(folder[..<i]) } else { folder = "" }
			let sub = folder.isEmpty ? rel : String(rel.dropFirst(folder.count + 1))
			let r = patterns(folder).match(sub, isDir: isDir)
			if r.decided { return r.ignored }
			if folder.isEmpty { break }
		}
		return exclude.match(rel, isDir: isDir).ignored
	}
}
