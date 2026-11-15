import Foundation
import Testing
@testable import MinorCore

struct SessionTests {
	@Test func takeReturnsExistingWindowsOnceAndOnlyWhenRestoring() throws {
		let dir = FileManager.default.temporaryDirectory.appendingPathComponent("SessionTests-\(UUID().uuidString)")
		try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: dir) }
		let file = dir.appendingPathComponent("a.go").path
		FileManager.default.createFile(atPath: file, contents: Data())
		let url = dir.appendingPathComponent("session.json")
		let windows = [Session.Window(project: dir.path, file: file), Session.Window(project: nil, file: dir.path + "/gone.go")]
		try Session(windows: windows, front: file, restore: true).save(to: url)
		#expect(Session.take(from: url)?.windows == [windows[0]])
		#expect(Session.take(from: url) == nil) // read once

		try Session(windows: windows, front: nil, restore: false).save(to: url)
		#expect(Session.take(from: url) == nil)
	}
}
