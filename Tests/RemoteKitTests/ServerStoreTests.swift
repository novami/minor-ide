import Foundation
import Testing
@testable import RemoteKit

@Suite struct ServerStoreTests {
	@Test func savesEditsAndRemovesWithoutPasswords() throws {
		let dir = FileManager.default.temporaryDirectory.appendingPathComponent("srv-" + UUID().uuidString)
		defer { try? FileManager.default.removeItem(at: dir) }
		let store = ServerStore(storeURL: dir.appendingPathComponent("servers.json"))
		var web = RemoteServer(name: "web", host: "example.com", user: "deploy", remotePath: "/var/www",
		                       production: true)
		let ftp = RemoteServer(name: "Hosting", kind: .ftps, host: "ftp.example.com", user: "u", authentication: .password)
		try store.save(web)
		try store.save(ftp)
		#expect(store.load().map(\.name) == ["Hosting", "web"])

		web.port = 2222
		try store.save(web)
		#expect(store.load().last == web)
		#expect(web.summary == "deploy@example.com:2222/var/www")

		let json = try String(contentsOf: store.storeURL, encoding: .utf8)
		#expect(json.contains("\"servers\""))
		#expect(!json.contains("\"password\" :"))

		try store.remove(id: web.id)
		#expect(store.load() == [ftp])
	}

	@Test func completenessAndPasswordDependOnKind() {
		var s = RemoteServer(name: "x", host: "h")
		#expect(s.isComplete)
		#expect(!s.usesPassword)
		s.port = 0
		#expect(!s.isComplete)
		s.port = nil
		s.kind = .ftps
		#expect(!s.isComplete) // FTPS needs a user
		#expect(s.usesPassword)
		s.user = "u"
		#expect(s.isComplete)
	}

	@Test func projectServersShareLocalSettingsAndStayOutOfGit() throws {
		let project = FileManager.default.temporaryDirectory.appendingPathComponent("prj-" + UUID().uuidString)
		defer { try? FileManager.default.removeItem(at: project) }
		let local = ServerStore.projectURL(project)
		try FileManager.default.createDirectory(at: local.deletingLastPathComponent(), withIntermediateDirectories: true)
		try #"{"paths": {"php": "/opt/php"}, "databases": [5]}"#.write(to: local, atomically: true, encoding: .utf8)

		let store = ServerStore(project: project)
		let web = RemoteServer(name: "web", host: "example.com", port: 2222)
		try store.save(web)
		#expect(store.load() == [web])
		let json = try JSONSerialization.jsonObject(with: Data(contentsOf: local)) as? [String: Any]
		#expect((json?["paths"] as? [String: String]) == ["php": "/opt/php"])
		#expect((json?["databases"] as? [Int]) == [5])

		let ignore = project.appendingPathComponent(".minoride/.gitignore")
		#expect(try String(contentsOf: ignore, encoding: .utf8) == "local.json\n")
		try store.save(web)
		#expect(try String(contentsOf: ignore, encoding: .utf8) == "local.json\n")

		try "{ broken".write(to: local, atomically: true, encoding: .utf8)
		#expect(store.load().isEmpty)
		#expect(throws: (any Error).self) { try store.save(web) }
		#expect(try String(contentsOf: local, encoding: .utf8) == "{ broken")
	}
}
