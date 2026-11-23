import Foundation
import Testing
import MinorCore
@testable import ProjectKit

@Suite struct FileSearcherTests {
	func project(_ files: [String: String]) throws -> URL {
		let root = FileManager.default.temporaryDirectory.appendingPathComponent("ps-" + UUID().uuidString)
		for (path, text) in files {
			let url = root.appendingPathComponent(path)
			try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
			try text.write(to: url, atomically: true, encoding: .utf8)
		}
		return root
	}

	func run(_ root: URL, _ o: FileSearchOptions) async throws -> ([FileSearchResult], FileSearchSummary) {
		let box = Box()
		let s = try await FileSearcher.search(root: root, o) { box.add($0) }
		return (box.items.sorted { $0.path < $1.path }, s)
	}

	@Test func literalAndIgnore() async throws {
		let root = try project(["a.go": "x\nfoo bar foo\n", "vendor/b.go": "foo", "sub/c.txt": "Foo\r\n", ".gitignore": "vendor/\n", "bin.dat": "foo\0"])
		var o = FileSearchOptions(query: "foo", caseSensitive: true)
		var (r, s) = try await run(root, o)
		#expect(r.map(\.path) == ["a.go"])
		#expect(r[0].lines == [FileSearchLine(line: 1, column: 0, text: "foo bar foo", ranges: [0..<3, 8..<11])])
		#expect(s.matches == 2 && s.files == 1)
		o.caseSensitive = false
		(r, _) = try await run(root, o)
		#expect(r.map(\.path) == ["a.go", "sub/c.txt"])
		#expect(r[1].lines[0].text == "Foo")
	}

	@Test func regexWholeWordUnicode() async throws {
		let root = try project(["u.txt": "žluť cat concat\n"])
		var o = FileSearchOptions(query: "cat", wholeWord: true)
		var (r, _) = try await run(root, o)
		#expect(r[0].lines[0].ranges == [7..<10]) // bytes: the letters ž and ť take two
		o = FileSearchOptions(query: "c\\w+t$", regex: true)
		(r, _) = try await run(root, o)
		#expect(r[0].lines[0].ranges == [11..<17])
		await #expect(throws: FileSearchError.invalidRegex) { _ = try await run(root, FileSearchOptions(query: "(", regex: true)) }
	}

	@Test func limitAndSkip() async throws {
		let root = try project(["a.txt": "x x x x", "b.txt": "x"])
		var o = FileSearchOptions(query: "x", caseSensitive: true)
		o.maxMatches = 2
		let (_, s) = try await run(root, o)
		#expect(s.truncated)
		o.maxMatches = 100
		o.skip = ["a.txt"]
		let (r, _) = try await run(root, o)
		#expect(r.map(\.path) == ["b.txt"])
	}
}

final class Box: @unchecked Sendable {
	private let lock = NSLock()
	private var all: [FileSearchResult] = []
	func add(_ r: FileSearchResult) { lock.withLock { all.append(r) } }
	var items: [FileSearchResult] { lock.withLock { all } }
}
