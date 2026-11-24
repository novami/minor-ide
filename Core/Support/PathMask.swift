import Foundation

/// A file mask like `*.php, src/**, !tests/**, !*.min.js`: patterns separated by commas or
/// spaces; a leading `!` excludes. A pattern without `/` matches the file name at any depth,
/// one with `/` the path relative to the project (`dir/` means everything below `dir`).
/// A path passes when no exclude matches and, if there are includes, one of them matches.
nonisolated public struct PathMask: Sendable, Equatable {
	struct Pattern: Sendable, Equatable {
		let glob: [UInt8]
		let anchored: Bool
	}

	let includes: [Pattern]
	let excludes: [Pattern]

	public init(_ text: String) {
		var inc: [Pattern] = [], exc: [Pattern] = []
		for word in text.split(whereSeparator: { $0 == "," || $0 == " " || $0 == "\n" }) {
			var s = Substring(word)
			let exclude = s.first == "!"
			if exclude { s = s.dropFirst() }
			if s.hasPrefix("/") { s = s.dropFirst() }
			if s.hasSuffix("/") { s += "**" }
			guard !s.isEmpty else { continue }
			let p = Pattern(glob: Array(s.utf8), anchored: s.contains("/"))
			if exclude { exc.append(p) } else { inc.append(p) }
		}
		includes = inc
		excludes = exc
	}

	public var isEmpty: Bool { includes.isEmpty && excludes.isEmpty }

	public func matches(_ relativePath: String) -> Bool {
		let path = Array(relativePath.utf8)
		let name = path.lastIndex(of: UInt8(ascii: "/")).map { Array(path[($0 + 1)...]) } ?? path
		func hit(_ p: Pattern) -> Bool { GitIgnore.glob(p.glob[...], (p.anchored ? path : name)[...]) }
		if excludes.contains(where: hit) { return false }
		return includes.isEmpty || includes.contains(where: hit)
	}
}
