import Foundation
import Testing
@testable import MinorCore

/// Requires the Go helper: `make server` builds server/bin/minoride-server.
struct FileSearchTests {
	@Test func streamsResultsPerFile() async throws {
		let server = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
			.appendingPathComponent("server/bin/minoride-server")
		let root = FileManager.default.temporaryDirectory.appendingPathComponent("FileSearchTests-\(UUID().uuidString)")
		defer { try? FileManager.default.removeItem(at: root) }
		try FileManager.default.createDirectory(at: root.appendingPathComponent("src"), withIntermediateDirectories: true)
		try "func Žluť() {}\nŽluť()\n".write(to: root.appendingPathComponent("src/a.go"), atomically: true, encoding: .utf8)
		try "žluť\n".write(to: root.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)

		let client = try FileSearchClient(server: server)
		let found = Locked<[FileSearchResult]>([])
		var options = FileSearchOptions(query: "Žluť", caseSensitive: true)
		options.skip = ["b.txt"]
		let summary = try await client.search(root: root, options) { r in found.mutate { $0.append(r) } }
		#expect(summary.files == 1 && summary.matches == 2)
		let a = found.value.first
		#expect(a?.path == "src/a.go")
		#expect(a?.lines.map(\.line) == [0, 1])
		#expect(a?.lines[0].ranges == [5..<11]) // bytes: "func " then 6 bytes of "Žluť"
	}
}

final class Locked<T>: @unchecked Sendable {
	private let lock = NSLock()
	private var stored: T
	init(_ value: T) { stored = value }
	var value: T { lock.withLock { stored } }
	func mutate(_ body: (inout T) -> Void) { lock.withLock { body(&stored) } }
}
