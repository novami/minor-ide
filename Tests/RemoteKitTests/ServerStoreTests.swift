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
}
