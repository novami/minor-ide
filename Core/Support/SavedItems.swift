import Foundation

/// An item the user saves (a database connection, a server), for all projects or for one.
nonisolated public protocol SavedItem: Codable, Sendable, Identifiable where ID == UUID {
	var name: String { get }
}

/// Saved items under one key of a JSON file, never with passwords: `{"<key>": [ … ]}` sorted
/// by name. Other keys of the file are kept (the project's `local.json` holds more). The file
/// is read on every query, so all windows agree.
nonisolated public struct SavedItemStore<Item: SavedItem>: Sendable {
	public let storeURL: URL
	public let key: String

	public init(storeURL: URL, key: String) {
		self.storeURL = storeURL
		self.key = key
	}

	/// `~/Library/Application Support/MinorIDE/<file>`, for all projects.
	public static func defaultURL(_ file: String) -> URL {
		FileManager.default.homeDirectoryForCurrentUser
			.appendingPathComponent("Library/Application Support/MinorIDE/" + file)
	}

	/// The project's personal settings `.minoride/local.json` (not read in Restricted Mode).
	public static func projectURL(_ project: URL) -> URL {
		project.appendingPathComponent(".minoride/local.json")
	}

	/// Items sorted by name; an unreadable file has none.
	public func load() -> [Item] {
		guard let items = (try? readFile())?[key],
		      let data = try? JSONSerialization.data(withJSONObject: items),
		      let decoded = try? JSONDecoder().decode([Item].self, from: data) else { return [] }
		return decoded
	}

	/// Adds the item or replaces the one with the same id.
	public func save(_ item: Item) throws {
		var all = load()
		if let i = all.firstIndex(where: { $0.id == item.id }) {
			all[i] = item
		} else {
			all.append(item)
		}
		try write(all)
	}

	public func remove(id: UUID) throws {
		let all = load()
		guard all.contains(where: { $0.id == id }) else { return }
		try write(all.filter { $0.id != id })
	}

	/// A missing file is empty; an unreadable one throws, so saving never overwrites it.
	private func readFile() throws -> [String: Any] {
		guard FileManager.default.fileExists(atPath: storeURL.path) else { return [:] }
		guard let object = try JSONSerialization.jsonObject(with: Data(contentsOf: storeURL)) as? [String: Any] else {
			throw CocoaError(.fileReadCorruptFile, userInfo: [NSFilePathErrorKey: storeURL.path])
		}
		return object
	}

	private func write(_ all: [Item]) throws {
		let folder = storeURL.deletingLastPathComponent()
		try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
		if storeURL.lastPathComponent == "local.json" && folder.lastPathComponent == ".minoride" {
			try ignoreLocalSettings(in: folder)
		}
		let sorted = all.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
		var file = try readFile()
		file[key] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(sorted))
		let data = try JSONSerialization.data(withJSONObject: file,
		                                      options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
		try data.write(to: storeURL, options: .atomic)
	}

	/// Personal settings stay out of the repository: `.minoride/.gitignore` lists `local.json`.
	private func ignoreLocalSettings(in folder: URL) throws {
		let ignore = folder.appendingPathComponent(".gitignore")
		let current = (try? String(contentsOf: ignore, encoding: .utf8)) ?? ""
		let lines = current.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
		guard !lines.contains("local.json"), !lines.contains("/local.json") else { return }
		let text = current.isEmpty || current.hasSuffix("\n") ? current : current + "\n"
		try (text + "local.json\n").write(to: ignore, atomically: true, encoding: .utf8)
	}
}
