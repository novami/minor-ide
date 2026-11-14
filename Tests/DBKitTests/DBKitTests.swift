import Foundation
import MinorCore
import Testing
@testable import DBKit

/// Requires the Go helper: `make server` builds server/bin/minoride-server.
func serverURL() throws -> URL {
	if let path = ProcessInfo.processInfo.environment["MINORIDE_SERVER"] {
		return URL(fileURLWithPath: path)
	}
	let url = URL(fileURLWithPath: #filePath)
		.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
		.appendingPathComponent("server/bin/minoride-server")
	guard FileManager.default.isExecutableFile(atPath: url.path) else {
		throw RPCError(code: 0, message: "missing \(url.path), run `make server`")
	}
	return url
}

struct DBKitTests {
	@Test func sqliteRoundTrip() async throws {
		let db = try DBClient(server: serverURL())
		defer { db.close() }
		#expect(try await db.ping() == "pong")

		let conn = try await db.connectSQLite(path: ":memory:")
		_ = try await db.query(conn, "CREATE TABLE t (id INTEGER, name TEXT)")
		_ = try await db.query(conn, "INSERT INTO t VALUES (?, ?)", args: [1, "Příliš žluťoučký"])
		let r = try await db.query(conn, "SELECT 1 AS one, name FROM t")
		#expect(r.columns.map(\.name) == ["one", "name"])
		#expect(r.rows == [[1, "Příliš žluťoučký"]])

		await #expect(throws: RPCError.self) { try await db.query(conn, "SELECT * FROM missing") }
		try await db.disconnect(conn)
	}
}
