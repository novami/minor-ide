import Foundation

/// Options of a find in files .
nonisolated public struct FileSearchOptions: Sendable, Equatable {
	public var query: String
	public var regex = false
	public var caseSensitive = false
	public var wholeWord = false
	/// Relative paths the caller searches itself (files with unsaved changes).
	public var skip: [String] = []
	public var maxMatches = 20_000
	/// File mask (`*.php, !tests/**`, see `PathMask`); empty means all files.
	public var mask = ""
	/// Folder relative to the project root to search in; empty means the whole project.
	public var folder = ""
	/// Search only these relative paths (open files) instead of walking the project.
	public var only: [String]?

	public init(query: String, regex: Bool = false, caseSensitive: Bool = false, wholeWord: Bool = false) {
		self.query = query
		self.regex = regex
		self.caseSensitive = caseSensitive
		self.wholeWord = wholeWord
	}
}

/// A line with matches. `ranges` are byte ranges in `text`; `column` is the byte column of
/// `text` in the line (a long line is cut around its first match).
nonisolated public struct FileSearchLine: Sendable, Equatable {
	public let line: Int
	public let column: Int
	public let text: String
	public let ranges: [Range<Int>]

	public init(line: Int, column: Int, text: String, ranges: [Range<Int>]) {
		self.line = line
		self.column = column
		self.text = text
		self.ranges = ranges
	}
}

/// Matches in one file; `path` is relative to the searched folder.
nonisolated public struct FileSearchResult: Sendable, Equatable {
	public let path: String
	public var lines: [FileSearchLine]

	public init(path: String, lines: [FileSearchLine]) {
		self.path = path
		self.lines = lines
	}

	public var matchCount: Int { lines.reduce(0) { $0 + $1.ranges.count } }
}

nonisolated public struct FileSearchSummary: Sendable, Equatable {
	public var files = 0
	public var matches = 0
	public var truncated = false
	public var cancelled = false
	public init() {}
}
