import Foundation
import MinorCore

/// A saved database connection. Passwords are never part of it: they live in the Keychain
/// under `passwordID`.
public struct DatabaseConnection: SavedItem, Equatable {
	public enum Kind: String, Codable, Sendable, CaseIterable {
		case mysql, postgresql, sqlite

		public var defaultPort: Int? {
			switch self {
			case .mysql: 3306
			case .postgresql: 5432
			case .sqlite: nil
			}
		}

		public var isNetwork: Bool { self != .sqlite }
	}

	/// A tunnel over the system `ssh -W` (D16): `~/.ssh/config` and ssh-agent apply.
	public struct SSHTunnel: Codable, Sendable, Equatable {
		public var host: String
		public var user: String
		/// Private key file; empty uses `~/.ssh/config` and the agent.
		public var keyFile: String

		public init(host: String = "", user: String = "", keyFile: String = "") {
			self.host = host
			self.user = user
			self.keyFile = keyFile
		}
	}

	public var id: UUID
	public var name: String
	public var kind: Kind
	public var host: String
	/// nil uses the kind's default port.
	public var port: Int?
	public var user: String
	public var database: String
	/// The database file of SQLite.
	public var file: String
	public var ssh: SSHTunnel?
	public var production: Bool

	public init(id: UUID = UUID(), name: String = "", kind: Kind = .mysql, host: String = "localhost",
	            port: Int? = nil, user: String = "", database: String = "", file: String = "",
	            ssh: SSHTunnel? = nil, production: Bool = false) {
		self.id = id
		self.name = name
		self.kind = kind
		self.host = host
		self.port = port
		self.user = user
		self.database = database
		self.file = file
		self.ssh = ssh
		self.production = production
	}

	/// Keychain account of the password.
	public var passwordID: String { "database." + id.uuidString }

	public var effectivePort: Int? { port ?? kind.defaultPort }

	/// Everything required for the kind is filled in.
	public var isComplete: Bool {
		guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
		if let port, !(1...65535).contains(port) { return false }
		if let ssh, ssh.host.trimmingCharacters(in: .whitespaces).isEmpty { return false }
		return kind.isNetwork ? !host.trimmingCharacters(in: .whitespaces).isEmpty : !file.isEmpty
	}

	/// A short description for lists: `user@host:port/database` or the file name.
	public var summary: String {
		guard kind.isNetwork else { return (file as NSString).lastPathComponent }
		var s = user.isEmpty ? host : user + "@" + host
		if let port, port != kind.defaultPort { s += ":\(port)" }
		if !database.isEmpty { s += "/" + database }
		return s
	}
}

/// Saved connections in `databases.json` (see `SavedItemStore`).
public typealias ConnectionStore = SavedItemStore<DatabaseConnection>

extension SavedItemStore where Item == DatabaseConnection {
	public init(storeURL: URL = ConnectionStore.defaultURL("databases.json")) {
		self.init(storeURL: storeURL, key: "databases")
	}
}
