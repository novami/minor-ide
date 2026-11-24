import Foundation
import XCTest
@testable import MinorIDE

final class ServerStoreTests: XCTestCase {
	func testSavesEditsAndRemovesWithoutPasswords() throws {
		let dir = FileManager.default.temporaryDirectory.appendingPathComponent("srv-" + UUID().uuidString)
		defer { try? FileManager.default.removeItem(at: dir) }
		let store = ServerStore(storeURL: dir.appendingPathComponent("servers.json"))
		var web = RemoteServer(name: "web", host: "example.com", user: "deploy", remotePath: "/var/www",
		                       production: true)
		let ftp = RemoteServer(name: "Hosting", kind: .ftps, host: "ftp.example.com", user: "u", authentication: .password)
		try store.save(web)
		try store.save(ftp)
		XCTAssertEqual(store.load().map(\.name), ["Hosting", "web"])

		web.port = 2222
		try store.save(web)
		XCTAssertEqual(store.load().last, web)
		XCTAssertEqual(web.summary, "deploy@example.com:2222/var/www")

		let json = try String(contentsOf: store.storeURL, encoding: .utf8)
		XCTAssertTrue(json.contains("\"servers\""))
		XCTAssertFalse(json.contains("\"password\" :"))

		try store.remove(id: web.id)
		XCTAssertEqual(store.load(), [ftp])
	}

	func testCompletenessAndPasswordDependOnKind() {
		var s = RemoteServer(name: "x", host: "h")
		XCTAssertTrue(s.isComplete)
		XCTAssertFalse(s.usesPassword)
		s.port = 0
		XCTAssertFalse(s.isComplete)
		s.port = nil
		s.kind = .ftps
		XCTAssertFalse(s.isComplete) // FTPS needs a user
		XCTAssertTrue(s.usesPassword)
		s.user = "u"
		XCTAssertTrue(s.isComplete)
	}

	func testProjectServersShareLocalSettingsAndStayOutOfGit() throws {
		let project = FileManager.default.temporaryDirectory.appendingPathComponent("prj-" + UUID().uuidString)
		defer { try? FileManager.default.removeItem(at: project) }
		let local = ServerStore.projectURL(project)
		try FileManager.default.createDirectory(at: local.deletingLastPathComponent(), withIntermediateDirectories: true)
		try #"{"paths": {"php": "/opt/php"}, "databases": [5]}"#.write(to: local, atomically: true, encoding: .utf8)

		let store = ServerStore(project: project)
		let web = RemoteServer(name: "web", host: "example.com", port: 2222)
		try store.save(web)
		XCTAssertEqual(store.load(), [web])
		let json = try JSONSerialization.jsonObject(with: Data(contentsOf: local)) as? [String: Any]
		XCTAssertEqual((json?["paths"] as? [String: String]), ["php": "/opt/php"])
		XCTAssertEqual((json?["databases"] as? [Int]), [5])

		let ignore = project.appendingPathComponent(".minoride/.gitignore")
		try XCTAssertEqual(String(contentsOf: ignore, encoding: .utf8), "local.json\n")
		try store.save(web)
		try XCTAssertEqual(String(contentsOf: ignore, encoding: .utf8), "local.json\n")

		try "{ broken".write(to: local, atomically: true, encoding: .utf8)
		XCTAssertTrue(store.load().isEmpty)
		XCTAssertThrowsError(try store.save(web))
		try XCTAssertEqual(String(contentsOf: local, encoding: .utf8), "{ broken")
	}
}
