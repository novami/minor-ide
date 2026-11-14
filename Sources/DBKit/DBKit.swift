import Foundation
import MinorCore

public struct QueryResult: Sendable {
	public struct Column: Sendable, Equatable {
		public let name: String
		public let type: String
	}

	public let columns: [Column]
	public let rows: [[JSONValue]]
	public let rowsAffected: Int
}

/// Client for `minoride-server db`.
public final class DBClient: Sendable {
	private let rpc: JSONRPCClient

	public init(server: URL) throws {
		rpc = try JSONRPCClient(executable: server, arguments: ["db"])
	}

	public func close() { rpc.terminate() }

	public func ping() async throws -> String {
		try await rpc.request("ping").stringValue ?? ""
	}

	/// Opens a SQLite database and returns its connection id.
	public func connectSQLite(path: String) async throws -> String {
		let r = try await rpc.request("connect", ["driver": "sqlite", "path": .string(path)])
		guard let id = r["conn"]?.stringValue else { throw RPCError(code: -32603, message: "missing conn id") }
		return id
	}

	public func query(_ conn: String, _ sql: String, args: [JSONValue] = []) async throws -> QueryResult {
		let r = try await rpc.request("query", ["conn": .string(conn), "sql": .string(sql), "args": .array(args)])
		let columns = (r["columns"]?.arrayValue ?? []).map {
			QueryResult.Column(name: $0["name"]?.stringValue ?? "", type: $0["type"]?.stringValue ?? "")
		}
		let rows = (r["rows"]?.arrayValue ?? []).map { $0.arrayValue ?? [] }
		return QueryResult(columns: columns, rows: rows, rowsAffected: Int(r["rowsAffected"]?.doubleValue ?? 0))
	}

	public func disconnect(_ conn: String) async throws {
		_ = try await rpc.request("disconnect", ["conn": .string(conn)])
	}
}
