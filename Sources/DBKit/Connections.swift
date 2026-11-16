import Foundation

/// A saved database connection. Passwords are never part of it: they live in the Keychain
/// under `passwordID`.
public struct DatabaseConnection: Codable, Sendable, Equatable, Identifiable {
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

/// Saved connections, stored outside every project (like `trusted.json`) and without
/// passwords. The file is read on every query, so all windows agree.
public struct ConnectionStore: Sendable {
	public let storeURL: URL

	public init(storeURL: URL = ConnectionStore.defaultURL) {
		self.storeURL = storeURL
	}

	public static var defaultURL: URL {
		FileManager.default.homeDirectoryForCurrentUser
			.appendingPathComponent("Library/Application Support/MinorIDE/databases.json")
	}

	private struct Store: Codable {
		var databases: [DatabaseConnection]
	}

	/// Connections sorted by name; an unreadable file has none.
	public func load() -> [DatabaseConnection] {
		guard let data = try? Data(contentsOf: storeURL),
		      let store = try? JSONDecoder().decode(Store.self, from: data) else { return [] }
		return store.databases
	}

	/// Adds the connection or replaces the one with the same id.
	public func save(_ connection: DatabaseConnection) throws {
		var all = load()
		if let i = all.firstIndex(where: { $0.id == connection.id }) {
			all[i] = connection
		} else {
			all.append(connection)
		}
		try write(all)
	}

	public func remove(id: UUID) throws {
		try write(load().filter { $0.id != id })
	}

	private func write(_ all: [DatabaseConnection]) throws {
		try FileManager.default.createDirectory(at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
		let encoder = JSONEncoder()
		encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
		let sorted = all.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
		try encoder.encode(Store(databases: sorted)).write(to: storeURL, options: .atomic)
	}
}
