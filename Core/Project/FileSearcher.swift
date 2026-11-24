import Foundation

nonisolated public enum FileSearchError: Error, Equatable {
	case emptyQuery
	case invalidRegex
}

/// Find in Files: files are read in parallel, `.gitignore` is respected and results are
/// reported per file as soon as a file is done.
nonisolated public enum FileSearcher {
	static let maxFileSize = 20 << 20
	/// How much of a long line is kept around its first match.
	static let maxLineText = 400

	/// Searches `root`; `onFile` is called (serialized, on a background thread) for every file
	/// with matches. Cancelling the task stops the search.
	public static func search(root: URL, _ options: FileSearchOptions, onFile: @escaping @Sendable (FileSearchResult) -> Void) async throws -> FileSearchSummary {
		let matcher = try Matcher(options)
		let limit = options.maxMatches > 0 ? options.maxMatches : 20_000
		let skip = Set(options.skip)
		let mask = PathMask(options.mask)
		let folderPrefix = options.folder.isEmpty ? "" : options.folder + "/"
		func wanted(_ rel: String) -> Bool { rel.hasPrefix(folderPrefix) && !skip.contains(rel) && mask.matches(rel) }
		let state = SearchState(limit: limit, emit: onFile)
		let (stream, feed) = AsyncStream.makeStream(of: String.self, bufferingPolicy: .bufferingOldest(512))
		await withTaskGroup(of: Void.self) { group in
			for _ in 0..<max(2, ProcessInfo.processInfo.activeProcessorCount) {
				group.addTask {
					for await rel in stream {
						if Task.isCancelled || state.isFull { continue }
						let left = limit - state.total
						guard let (result, count) = searchFile(root.appendingPathComponent(rel), rel: rel, matcher, limit: left) else { continue }
						state.add(result, count: count)
					}
				}
			}
			group.addTask {
				// The walk blocks on a full buffer, so it runs off the cooperative pool's fast path.
				func send(_ rel: String) -> Bool {
					if state.isFull { return false }
					guard wanted(rel) else { return true }
					while case .dropped = feed.yield(rel) {
						if Task.isCancelled || state.isFull { return false }
						Thread.sleep(forTimeInterval: 0.001)
					}
					return true
				}
				if let only = options.only {
					for rel in only where !send(rel) { break }
				} else {
					FileWalker.walk(root: root, ignore: GitIgnoreSet(root: root), visit: send)
				}
				feed.finish()
			}
		}
		var s = FileSearchSummary()
		(s.files, s.matches, s.truncated) = state.snapshot()
		s.cancelled = Task.isCancelled
		return s
	}

	// MARK: - One file

	/// The matches of one file grouped by line, and their count; nil without matches.
	static func searchFile(_ url: URL, rel: String, _ matcher: Matcher, limit: Int) -> (FileSearchResult, Int)? {
		guard limit > 0, let v = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]), v.isRegularFile == true,
		      (v.fileSize ?? 0) <= maxFileSize, let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
		return data.withUnsafeBytes { raw -> (FileSearchResult, Int)? in
			let bytes = raw.bindMemory(to: UInt8.self)
			if memchr(bytes.baseAddress, 0, min(bytes.count, 8000)) != nil { return nil } // binary
			let found = matcher.find(in: bytes, data: data, limit: limit)
			guard !found.isEmpty else { return nil }
			return (FileSearchResult(path: rel, lines: group(found, bytes)), found.count)
		}
	}

	private static func group(_ found: [Range<Int>], _ b: UnsafeBufferPointer<UInt8>) -> [FileSearchLine] {
		struct Open { var line: Int, column: Int, text: [UInt8], ranges: [Range<Int>] }
		var out: [Open] = []
		var line = 0, lineStart = 0, scanned = 0
		let nl = UInt8(ascii: "\n")
		for f in found {
			while scanned < f.lowerBound, let i = (scanned..<f.lowerBound).first(where: { b[$0] == nl }) {
				line += 1
				lineStart = i + 1
				scanned = lineStart
			}
			scanned = max(scanned, f.lowerBound)
			var lineEnd = lineStart
			while lineEnd < b.count, b[lineEnd] != nl { lineEnd += 1 }
			let start = f.lowerBound - lineStart, stop = min(f.upperBound, lineEnd) - lineStart // a match across lines is cut
			if var last = out.last, last.line == line {
				let s = start - last.column, e = stop - last.column
				if s >= 0, e <= last.text.count, s <= e { last.ranges.append(s..<e); out[out.count - 1] = last }
				continue
			}
			var text = Array(b[lineStart..<lineEnd])
			var column = 0
			if text.count > maxLineText {
				column = utf8Start(text, max(0, start - maxLineText / 4))
				let cut = utf8Start(text, min(text.count, column + maxLineText))
				text = Array(text[column..<cut])
			}
			while text.last == UInt8(ascii: "\r") { text.removeLast() }
			let s = start - column
			out.append(Open(line: line, column: column, text: text, ranges: [s..<max(s, min(stop - column, text.count))]))
		}
		return out.map { FileSearchLine(line: $0.line, column: $0.column, text: String(decoding: $0.text, as: UTF8.self), ranges: $0.ranges) }
	}

	private static func utf8Start(_ b: [UInt8], _ index: Int) -> Int {
		var i = index
		while i > 0, i < b.count, b[i] & 0xC0 == 0x80 { i -= 1 }
		return i
	}
}

nonisolated private final class SearchState: @unchecked Sendable {
	private let lock = NSLock()
	private let limit: Int
	private let emit: @Sendable (FileSearchResult) -> Void
	private var matches = 0, files = 0

	init(limit: Int, emit: @escaping @Sendable (FileSearchResult) -> Void) {
		self.limit = limit
		self.emit = emit
	}

	var total: Int { lock.withLock { matches } }
	var isFull: Bool { lock.withLock { matches >= limit } }

	func add(_ result: FileSearchResult, count: Int) {
		lock.lock()
		defer { lock.unlock() }
		matches += count
		files += 1
		emit(result)
	}

	func snapshot() -> (Int, Int, Bool) { lock.withLock { (files, matches, matches >= limit) } }
}

/// Literal text (a byte search) or a regular expression (ICU, over the UTF-8 text).
nonisolated struct Matcher: Sendable {
	private let literal: [UInt8]?
	private let regex: NSRegularExpression?

	init(_ o: FileSearchOptions) throws {
		guard !o.query.isEmpty else { throw FileSearchError.emptyQuery }
		if !o.regex, o.caseSensitive, !o.wholeWord {
			literal = Array(o.query.utf8)
			regex = nil
			return
		}
		literal = nil
		var expr = o.regex ? o.query : NSRegularExpression.escapedPattern(for: o.query)
		if o.wholeWord { expr = "\\b(?:" + expr + ")\\b" }
		var opts: NSRegularExpression.Options = [.anchorsMatchLines]
		if !o.caseSensitive { opts.insert(.caseInsensitive) }
		do { regex = try NSRegularExpression(pattern: expr, options: opts) } catch { throw FileSearchError.invalidRegex }
	}

	/// Byte ranges of the matches (at most `limit`); empty matches are not results.
	func find(in b: UnsafeBufferPointer<UInt8>, data: Data, limit: Int) -> [Range<Int>] {
		var out: [Range<Int>] = []
		if let literal, let base = b.baseAddress {
			let n = literal.count
			var at = 0
			while out.count < limit, at + n <= b.count,
			      let p = memmem(base + at, b.count - at, literal, n) {
				let i = base.distance(to: p.assumingMemoryBound(to: UInt8.self))
				out.append(i..<i + n)
				at = i + n
			}
			return out
		}
		guard let regex, let text = String(validatingUTF8Data: data) else { return out } // invalid UTF-8: not text
		let ns = text as NSString
		let ascii = ns.length == b.count
		regex.enumerateMatches(in: text, range: NSRange(location: 0, length: ns.length)) { m, _, stop in
			guard let r = m?.range, r.length > 0 else { return }
			if ascii {
				out.append(r.location..<r.location + r.length)
			} else {
				let lo = text.utf16.index(text.utf16.startIndex, offsetBy: r.location), hi = text.utf16.index(lo, offsetBy: r.length)
				out.append(text.utf8.distance(from: text.utf8.startIndex, to: lo)..<text.utf8.distance(from: text.utf8.startIndex, to: hi))
			}
			if out.count >= limit { stop.pointee = true }
		}
		return out
	}
}

nonisolated private extension String {
	/// nil unless the data is valid UTF-8.
	init?(validatingUTF8Data data: Data) {
		guard let s = String(data: data, encoding: .utf8) else { return nil }
		self = s
	}
}
