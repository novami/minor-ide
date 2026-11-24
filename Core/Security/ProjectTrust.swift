import Foundation

/// Which project folders the user trusts (D18). Stored outside every project in
/// ~/Library/Application Support/MinorIDE/trusted.json, so a repository cannot bring its own
/// trust. An unknown project runs in Restricted Mode: no tools, Git, language servers,
/// debugger or commands from its settings, and `.minoride/local.json` is not read.
/// The file is read on every query, so all windows agree; an unreadable file trusts nothing.
nonisolated public struct ProjectTrust: Sendable {
	public let storeURL: URL

	public init(storeURL: URL = ProjectTrust.defaultURL) {
		self.storeURL = storeURL
	}

	public static var defaultURL: URL {
		FileManager.default.homeDirectoryForCurrentUser
			.appendingPathComponent("Library/Application Support/MinorIDE/trusted.json")
	}

	/// The folder's path with symbolic links resolved, the key of the store.
	public static func key(_ folder: URL) -> String {
		folder.standardizedFileURL.resolvingSymlinksInPath().path
	}

	public func isTrusted(_ folder: URL) -> Bool {
		load().contains(Self.key(folder))
	}

	public func setTrusted(_ trusted: Bool, _ folder: URL) throws {
		var paths = load()
		let key = Self.key(folder)
		if trusted { paths.insert(key) } else { paths.remove(key) }
		try save(paths)
	}

	private struct Store: Codable {
		var trusted: [String]
	}

	private func load() -> Set<String> {
		guard let data = try? Data(contentsOf: storeURL),
		      let store = try? JSONDecoder().decode(Store.self, from: data) else { return [] }
		return Set(store.trusted)
	}

	private func save(_ paths: Set<String>) throws {
		try FileManager.default.createDirectory(at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
		let encoder = JSONEncoder()
		encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
		try encoder.encode(Store(trusted: paths.sorted())).write(to: storeURL, options: .atomic)
	}
}
