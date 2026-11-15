import Foundation
import Testing
@testable import MinorCore

struct BackupsTests {
	@Test func savesReplacesAndRemovesBackups() throws {
		let root = FileManager.default.temporaryDirectory.appendingPathComponent("BackupsTests-\(UUID().uuidString)")
		defer { try? FileManager.default.removeItem(at: root) }
		let store = BackupStore(root: root)
		try store.save(DocumentBackup(id: "a", path: "/p/a.go", text: "one", date: Date(timeIntervalSince1970: 2)))
		try store.save(DocumentBackup(id: "a", path: "/p/a.go", text: "two", date: Date(timeIntervalSince1970: 2)))
		try store.save(DocumentBackup(id: "b", path: nil, text: "untitled", date: Date(timeIntervalSince1970: 1)))
		#expect(store.all().map(\.text) == ["untitled", "two"])
		let attributes = try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent("a.json").path)
		#expect(attributes[.posixPermissions] as? Int == 0o600)
		store.remove("a")
		#expect(store.all().map(\.id) == ["b"])
	}
}
