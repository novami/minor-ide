import Foundation

/// An item the user saves for all projects (a database connection, a server).
public protocol SavedItem: Codable, Sendable, Identifiable where ID == UUID {
	var name: String { get }
}

/// Saved items in one JSON file outside every project (like `trusted.json`), never with
/// passwords: `{"<key>": [ … ]}` sorted by name. The file is read on every query, so all
/// windows agree.
public struct SavedItemStore<Item: SavedItem>: Sendable {
	public let storeURL: URL
	public let key: String

	public init(storeURL: URL, key: String) {
		self.storeURL = storeURL
		self.key = key
	}

	/// `~/Library/Application Support/MinorIDE/<file>`.
	public static func defaultURL(_ file: String) -> URL {
		FileManager.default.homeDirectoryForCurrentUser
			.appendingPathComponent("Library/Application Support/MinorIDE/" + file)
	}

	/// Items sorted by name; an unreadable file has none.
	public func load() -> [Item] {
		guard let data = try? Data(contentsOf: storeURL),
		      let store = try? JSONDecoder().decode([String: [Item]].self, from: data) else { return [] }
		return store[key] ?? []
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
		try write(load().filter { $0.id != id })
	}

	private func write(_ all: [Item]) throws {
		try FileManager.default.createDirectory(at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
		let encoder = JSONEncoder()
		encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
		let sorted = all.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
		try encoder.encode([key: sorted]).write(to: storeURL, options: .atomic)
	}
}
