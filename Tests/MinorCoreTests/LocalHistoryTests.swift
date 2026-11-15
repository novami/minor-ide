import Foundation
import Testing
@testable import MinorCore

struct LocalHistoryTests {
	@Test func recordsVersionsSkipsDuplicatesAndPrunes() throws {
		let root = FileManager.default.temporaryDirectory.appendingPathComponent("LocalHistoryTests-\(UUID().uuidString)")
		defer { try? FileManager.default.removeItem(at: root) }
		let history = LocalHistory(root: root)
		let now = Date()
		try history.record(Data("one".utf8), for: "/p/a.php", date: now.addingTimeInterval(-20 * 86_400))
		try history.record(Data("two".utf8), for: "/p/a.php", date: now)
		try history.record(Data("two".utf8), for: "/p/a.php", date: now.addingTimeInterval(1))
		try history.record(Data("x".utf8), for: "/p/b.php", date: now)
		let versions = history.versions(of: "/p/a.php")
		#expect(versions.count == 2)
		#expect(try Data(contentsOf: versions[0].url) == Data("two".utf8))
		#expect((try FileManager.default.attributesOfItem(atPath: versions[0].url.path)[.posixPermissions] as? Int) == 0o600)

		history.prune(now: now)
		#expect(history.versions(of: "/p/a.php").map(\.size) == [3])
		#expect(history.versions(of: "/p/b.php").count == 1)
	}
}
