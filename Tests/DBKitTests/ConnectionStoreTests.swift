import Foundation
import Testing
@testable import DBKit

@Suite struct ConnectionStoreTests {
	@Test func savesEditsAndRemovesWithoutPasswords() throws {
		let dir = FileManager.default.temporaryDirectory.appendingPathComponent("db-" + UUID().uuidString)
		defer { try? FileManager.default.removeItem(at: dir) }
		let store = ConnectionStore(storeURL: dir.appendingPathComponent("store/databases.json"))
		#expect(store.load().isEmpty)

		var shop = DatabaseConnection(name: "shop", kind: .postgresql, host: "db.example.com", user: "app",
		                              database: "shop", ssh: .init(host: "bastion"), production: true)
		let local = DatabaseConnection(name: "Local", kind: .sqlite, file: "/tmp/a.sqlite")
		try store.save(shop)
		try store.save(local)
		#expect(store.load().map(\.name) == ["Local", "shop"])

		shop.port = 6432
		try store.save(shop)
		#expect(store.load().count == 2)
		#expect(store.load().last == shop)
		#expect(shop.summary == "app@db.example.com:6432/shop")
		#expect(local.summary == "a.sqlite")

		let json = try String(contentsOf: store.storeURL, encoding: .utf8)
		#expect(!json.lowercased().contains("password"))

		try store.remove(id: shop.id)
		#expect(store.load() == [local])
	}

	@Test func completenessDependsOnKind() {
		var c = DatabaseConnection(name: "x", kind: .mysql, host: "")
		#expect(!c.isComplete)
		c.host = "localhost"
		#expect(c.isComplete)
		c.port = 70000
		#expect(!c.isComplete)
		c.port = nil
		c.ssh = .init()
		#expect(!c.isComplete)
		c = DatabaseConnection(name: "x", kind: .sqlite)
		#expect(!c.isComplete)
		c.file = "/tmp/x.db"
		#expect(c.isComplete)
	}
}
