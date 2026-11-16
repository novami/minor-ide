import Foundation
import MinorCore

/// A saved SFTP or FTPS server. The password is never part of it: it lives in the Keychain
/// under `passwordID`. Mapping to project folders comes with phase 6b.
public struct RemoteServer: SavedItem, Equatable {
	public enum Kind: String, Codable, Sendable, CaseIterable {
		/// SFTP over the system `ssh` (D14): `~/.ssh/config` and ssh-agent apply.
		case sftp
		/// FTP over explicit TLS (D15); plain FTP is not supported.
		case ftps

		public var defaultPort: Int {
			switch self {
			case .sftp: 22
			case .ftps: 21
			}
		}
	}

	public enum Authentication: String, Codable, Sendable {
		/// A key file, or `~/.ssh/config` and the agent when `keyFile` is empty (SFTP only).
		case key
		case password
	}

	public var id: UUID
	public var name: String
	public var kind: Kind
	public var host: String
	/// nil uses the kind's default port.
	public var port: Int?
	public var user: String
	public var authentication: Authentication
	/// Private key file for `.key`; empty uses `~/.ssh/config` and the agent.
	public var keyFile: String
	/// The remote root folder; empty is the login folder.
	public var remotePath: String
	public var production: Bool

	public init(id: UUID = UUID(), name: String = "", kind: Kind = .sftp, host: String = "", port: Int? = nil,
	            user: String = "", authentication: Authentication = .key, keyFile: String = "",
	            remotePath: String = "", production: Bool = false) {
		self.id = id
		self.name = name
		self.kind = kind
		self.host = host
		self.port = port
		self.user = user
		self.authentication = authentication
		self.keyFile = keyFile
		self.remotePath = remotePath
		self.production = production
	}

	/// Keychain account of the password.
	public var passwordID: String { "server." + id.uuidString }

	public var effectivePort: Int { port ?? kind.defaultPort }

	/// FTPS always logs in with a password; SFTP as chosen.
	public var usesPassword: Bool { kind == .ftps || authentication == .password }

	/// Everything required for the kind is filled in. SFTP may take the user from `~/.ssh/config`.
	public var isComplete: Bool {
		func filled(_ s: String) -> Bool { !s.trimmingCharacters(in: .whitespaces).isEmpty }
		guard filled(name), filled(host) else { return false }
		if let port, !(1...65535).contains(port) { return false }
		return kind == .sftp || filled(user)
	}

	/// A short description for lists: `user@host:port/path`.
	public var summary: String {
		var s = user.isEmpty ? host : user + "@" + host
		if let port, port != kind.defaultPort { s += ":\(port)" }
		if !remotePath.isEmpty { s += remotePath.hasPrefix("/") ? remotePath : "/" + remotePath }
		return s
	}
}

/// Saved servers in `servers.json` for all projects, or a project's own (see `SavedItemStore`).
public typealias ServerStore = SavedItemStore<RemoteServer>

extension SavedItemStore where Item == RemoteServer {
	public init(storeURL: URL = ServerStore.defaultURL("servers.json")) {
		self.init(storeURL: storeURL, key: "servers")
	}

	/// The project's own servers in `.minoride/local.json`.
	public init(project: URL) {
		self.init(storeURL: ServerStore.projectURL(project), key: "servers")
	}
}
