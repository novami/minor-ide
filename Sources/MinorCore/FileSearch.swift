import Foundation

/// Options of a find in files (`minoride-server search`).
public struct FileSearchOptions: Sendable, Equatable {
	public var query: String
	public var regex = false
	public var caseSensitive = false
	public var wholeWord = false
	/// Relative paths the caller searches itself (files with unsaved changes).
	public var skip: [String] = []
	public var maxMatches = 20_000

	public init(query: String, regex: Bool = false, caseSensitive: Bool = false, wholeWord: Bool = false) {
		self.query = query
		self.regex = regex
		self.caseSensitive = caseSensitive
		self.wholeWord = wholeWord
	}
}

/// A line with matches. `ranges` are byte ranges in `text`; `column` is the byte column of
/// `text` in the line (a long line is cut around its first match).
public struct FileSearchLine: Sendable, Equatable {
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
public struct FileSearchResult: Sendable, Equatable {
	public let path: String
	public var lines: [FileSearchLine]

	public init(path: String, lines: [FileSearchLine]) {
		self.path = path
		self.lines = lines
	}

	public var matchCount: Int { lines.reduce(0) { $0 + $1.ranges.count } }
}

public struct FileSearchSummary: Sendable, Equatable {
	public var files = 0
	public var matches = 0
	public var truncated = false
	public var cancelled = false
	public init() {}
}

/// Client of `minoride-server search`: one helper process, several searches by id, results
/// streamed per file.
public final class FileSearchClient: @unchecked Sendable {
	private let rpc: JSONRPCClient
	private let lock = NSLock()
	private var handlers: [Int: @Sendable (FileSearchResult) -> Void] = [:]
	private var nextID = 1

	public init(server: URL) throws {
		rpc = try JSONRPCClient(executable: server, arguments: ["search"])
		rpc.onNotification = { [weak self] method, params in
			guard method == "search/file", let self, let id = params["id"]?.doubleValue,
			      let handler = lock.withLock({ handlers[Int(id)] }) else { return }
			handler(Self.result(params))
		}
	}

	deinit { rpc.terminate() }

	/// Searches `root`; `onFile` runs on a background queue for every file with matches.
	/// Cancelling the task cancels the search.
	public func search(root: URL, _ options: FileSearchOptions, onFile: @escaping @Sendable (FileSearchResult) -> Void) async throws -> FileSearchSummary {
		let id = lock.withLock {
			defer { nextID += 1 }
			handlers[nextID] = onFile
			return nextID
		}
		defer { _ = lock.withLock { handlers.removeValue(forKey: id) } }
		let params: JSONValue = [
			"id": .number(Double(id)), "root": .string(root.path), "query": .string(options.query),
			"regex": .bool(options.regex), "caseSensitive": .bool(options.caseSensitive), "wholeWord": .bool(options.wholeWord),
			"skip": .array(options.skip.map(JSONValue.string)), "maxMatches": .number(Double(options.maxMatches)),
		]
		let r = try await withTaskCancellationHandler {
			try await rpc.request("search", params)
		} onCancel: {
			try? rpc.notify("cancel", ["id": .number(Double(id))])
		}
		var s = FileSearchSummary()
		s.files = Int(r["files"]?.doubleValue ?? 0)
		s.matches = Int(r["matches"]?.doubleValue ?? 0)
		s.truncated = r["truncated"] == .bool(true)
		s.cancelled = r["cancelled"] == .bool(true)
		return s
	}

	static func result(_ p: JSONValue) -> FileSearchResult {
		let lines = (p["matches"]?.arrayValue ?? []).map { m in
			FileSearchLine(line: Int(m["line"]?.doubleValue ?? 0), column: Int(m["column"]?.doubleValue ?? 0),
			               text: m["text"]?.stringValue ?? "",
			               ranges: (m["ranges"]?.arrayValue ?? []).compactMap { r in
			               	guard let a = r.arrayValue, a.count == 2, let lo = a[0].doubleValue, let hi = a[1].doubleValue else { return nil }
			               	return Int(lo)..<Int(max(lo, hi))
			               })
		}
		return FileSearchResult(path: p["path"]?.stringValue ?? "", lines: lines)
	}
}
