import Foundation

/// Unsaved text kept while documents are edited, for recovery after a crash. A backup is
/// removed when its document is saved, reloaded or its changes are discarded, so backups
/// found at launch are what a crash left behind. Only the user can read them.
nonisolated public struct DocumentBackup: Codable, Sendable, Equatable {
	public var id: String
	/// The file, or nil for an untitled document.
	public var path: String?
	public var text: String
	public var date: Date

	public init(id: String, path: String?, text: String, date: Date = Date()) {
		self.id = id
		self.path = path
		self.text = text
		self.date = date
	}
}

nonisolated public struct BackupStore: Sendable {
	public let root: URL

	public init(root: URL = BackupStore.defaultRoot) { self.root = root }

	public static var defaultRoot: URL {
		FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/MinorIDE/Backups")
	}

	private func file(_ id: String) -> URL { root.appendingPathComponent(id + ".json") }

	public func save(_ backup: DocumentBackup) throws {
		let fm = FileManager.default
		try fm.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
		let data = try JSONEncoder().encode(backup)
		let temp = root.appendingPathComponent("." + backup.id + ".tmp")
		guard fm.createFile(atPath: temp.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
			throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: temp.path])
		}
		_ = try fm.replaceItemAt(file(backup.id), withItemAt: temp)
	}

	public func remove(_ id: String) {
		try? FileManager.default.removeItem(at: file(id))
	}

	/// Backups left behind, oldest first (unreadable ones are skipped).
	public func all() -> [DocumentBackup] {
		let files = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
		return files.filter { $0.pathExtension == "json" }
			.compactMap { try? JSONDecoder().decode(DocumentBackup.self, from: Data(contentsOf: $0)) }
			.sorted { $0.date < $1.date }
	}
}
