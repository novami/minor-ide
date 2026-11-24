import Foundation
import XCTest
@testable import MinorIDE

final class LocalHistoryTests: XCTestCase {
	func testRecordsVersionsSkipsDuplicatesAndPrunes() throws {
		let root = FileManager.default.temporaryDirectory.appendingPathComponent("LocalHistoryTests-\(UUID().uuidString)")
		defer { try? FileManager.default.removeItem(at: root) }
		let history = LocalHistory(root: root)
		let now = Date()
		try history.record(Data("one".utf8), for: "/p/a.php", date: now.addingTimeInterval(-20 * 86_400))
		try history.record(Data("two".utf8), for: "/p/a.php", date: now)
		try history.record(Data("two".utf8), for: "/p/a.php", date: now.addingTimeInterval(1))
		try history.record(Data("x".utf8), for: "/p/b.php", date: now)
		let versions = history.versions(of: "/p/a.php")
		XCTAssertEqual(versions.count, 2)
		try XCTAssertEqual(Data(contentsOf: versions[0].url), Data("two".utf8))
		XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: versions[0].url.path)[.posixPermissions] as? Int), 0o600)

		history.prune(now: now)
		XCTAssertEqual(history.versions(of: "/p/a.php").map(\.size), [3])
		XCTAssertEqual(history.versions(of: "/p/b.php").count, 1)
	}
}
