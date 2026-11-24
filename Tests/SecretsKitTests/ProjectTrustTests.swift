import Foundation
import XCTest
@testable import MinorIDE

final class ProjectTrustTests: XCTestCase {
	private func temp() throws -> URL {
		let dir = FileManager.default.temporaryDirectory.appendingPathComponent("trust-" + UUID().uuidString)
		try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
		return dir
	}

	func testTrustIsStoredOutsideTheProjectPerPath() throws {
		let dir = try temp()
		defer { try? FileManager.default.removeItem(at: dir) }
		let project = dir.appendingPathComponent("app")
		let other = dir.appendingPathComponent("app-other")
		try FileManager.default.createDirectory(at: project.appendingPathComponent(".minoride"), withIntermediateDirectories: true)
		// A project's own files never make it trusted.
		try Data(#"{"trusted": true}"#.utf8).write(to: project.appendingPathComponent(".minoride/local.json"))
		let trust = ProjectTrust(storeURL: dir.appendingPathComponent("store/trusted.json"))
		XCTAssertFalse(trust.isTrusted(project))

		try trust.setTrusted(true, project)
		XCTAssertTrue(trust.isTrusted(project))
		XCTAssertFalse(trust.isTrusted(other))
		XCTAssertFalse(trust.isTrusted(project.appendingPathComponent("sub")))

		// A symbolic link to the project is the same project.
		let link = dir.appendingPathComponent("link")
		try FileManager.default.createSymbolicLink(at: link, withDestinationURL: project)
		XCTAssertTrue(trust.isTrusted(link))

		try trust.setTrusted(false, project)
		XCTAssertFalse(trust.isTrusted(project))
	}

	func testUnreadableStoreTrustsNothing() throws {
		let dir = try temp()
		defer { try? FileManager.default.removeItem(at: dir) }
		let store = dir.appendingPathComponent("trusted.json")
		try Data("{broken".utf8).write(to: store)
		XCTAssertFalse(ProjectTrust(storeURL: store).isTrusted(dir))
	}
}
