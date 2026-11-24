import Foundation
import XCTest
@testable import MinorIDE

/// Requires the Go helper: `make server` builds server/bin/minoride-server.
func serverURL() throws -> URL {
	if let path = ProcessInfo.processInfo.environment["MINORIDE_SERVER"] {
		return URL(fileURLWithPath: path)
	}
	let url = URL(fileURLWithPath: #filePath)
		.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
		.appendingPathComponent("server/bin/minoride-server")
	guard FileManager.default.isExecutableFile(atPath: url.path) else {
		throw XCTSkip("Go helper missing at \(url.path); run `make server` or set MINORIDE_SERVER")
	}
	return url
}

final class DBKitTests: XCTestCase {
	func testSqliteRoundTrip() async throws {
		let db = try DBClient(server: serverURL())
		defer { db.close() }
		let pong = try await db.ping()
		XCTAssertEqual(pong, "pong")

		let conn = try await db.connectSQLite(path: ":memory:")
		_ = try await db.query(conn, "CREATE TABLE t (id INTEGER, name TEXT)")
		_ = try await db.query(conn, "INSERT INTO t VALUES (?, ?)", args: [1, "Příliš žluťoučký"])
		let r = try await db.query(conn, "SELECT 1 AS one, name FROM t")
		XCTAssertEqual(r.columns.map(\.name), ["one", "name"])
		XCTAssertEqual(r.rows, [[1, "Příliš žluťoučký"]])

		do { _ = try await db.query(conn, "SELECT * FROM missing"); XCTFail("expected an error") } catch {}
		try await db.disconnect(conn)
	}
}
