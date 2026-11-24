import Foundation
import XCTest
@testable import MinorIDE

final class ConnectionStoreTests: XCTestCase {
	func testSavesEditsAndRemovesWithoutPasswords() throws {
		let dir = FileManager.default.temporaryDirectory.appendingPathComponent("db-" + UUID().uuidString)
		defer { try? FileManager.default.removeItem(at: dir) }
		let store = ConnectionStore(storeURL: dir.appendingPathComponent("store/databases.json"))
		XCTAssertTrue(store.load().isEmpty)

		var shop = DatabaseConnection(name: "shop", kind: .postgresql, host: "db.example.com", user: "app",
		                              database: "shop", ssh: .init(host: "bastion"), production: true)
		let local = DatabaseConnection(name: "Local", kind: .sqlite, file: "/tmp/a.sqlite")
		try store.save(shop)
		try store.save(local)
		XCTAssertEqual(store.load().map(\.name), ["Local", "shop"])

		shop.port = 6432
		try store.save(shop)
		XCTAssertEqual(store.load().count, 2)
		XCTAssertEqual(store.load().last, shop)
		XCTAssertEqual(shop.summary, "app@db.example.com:6432/shop")
		XCTAssertEqual(local.summary, "a.sqlite")

		let json = try String(contentsOf: store.storeURL, encoding: .utf8)
		XCTAssertFalse(json.lowercased().contains("password"))

		try store.remove(id: shop.id)
		XCTAssertEqual(store.load(), [local])
	}

	func testCompletenessDependsOnKind() {
		var c = DatabaseConnection(name: "x", kind: .mysql, host: "")
		XCTAssertFalse(c.isComplete)
		c.host = "localhost"
		XCTAssertTrue(c.isComplete)
		c.port = 70000
		XCTAssertFalse(c.isComplete)
		c.port = nil
		c.ssh = .init()
		XCTAssertFalse(c.isComplete)
		c = DatabaseConnection(name: "x", kind: .sqlite)
		XCTAssertFalse(c.isComplete)
		c.file = "/tmp/x.db"
		XCTAssertTrue(c.isComplete)
	}
}
