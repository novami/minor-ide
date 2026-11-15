import Foundation

/// A file or folder of the project tree. Children are read from disk on first use and
/// re-read on `reload()`, which keeps existing nodes (and so the outline's expansion state).
public final class FileNode {
	public let url: URL
	public let isDirectory: Bool
	public private(set) weak var parent: FileNode?
	private var loaded: [FileNode]?

	/// Never shown: version control internals and Finder metadata.
	public static let hiddenNames: Set<String> = [".git", ".DS_Store", ".svn", ".hg"]

	public init(url: URL, isDirectory: Bool, parent: FileNode? = nil) {
		self.url = url.standardizedFileURL
		self.isDirectory = isDirectory
		self.parent = parent
	}

	public var name: String { url.lastPathComponent }
	public var isLoaded: Bool { loaded != nil }

	/// Folders first, then files, in Finder order (numbers compared as numbers).
	public var children: [FileNode] {
		if loaded == nil { reload() }
		return loaded ?? []
	}

	/// Reads the folder again; returns true when the list of children changed.
	@discardableResult
	public func reload() -> Bool {
		guard isDirectory else { return false }
		let keys: [URLResourceKey] = [.isDirectoryKey]
		let urls = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: keys)) ?? []
		let old = Dictionary((loaded ?? []).map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
		let fresh: [FileNode] = urls.compactMap { u in
			let name = u.lastPathComponent
			guard !FileNode.hiddenNames.contains(name) else { return nil }
			let dir = (try? u.resourceValues(forKeys: Set(keys)).isDirectory) ?? false
			if let existing = old[name], existing.isDirectory == dir { return existing }
			return FileNode(url: u, isDirectory: dir, parent: self)
		}.sorted { a, b in
			a.isDirectory != b.isDirectory ? a.isDirectory : a.name.localizedStandardCompare(b.name) == .orderedAscending
		}
		let changed = fresh.map(\.name) != (loaded ?? []).map(\.name) || loaded == nil
		loaded = fresh
		return changed
	}

	/// The loaded node for a URL inside this folder, nil when it is not loaded yet.
	public func loadedNode(for target: URL) -> FileNode? {
		let path = target.standardizedFileURL.path
		if path == url.path { return self }
		guard path.hasPrefix(url.path + "/"), let loaded else { return nil }
		for child in loaded where path == child.url.path || path.hasPrefix(child.url.path + "/") {
			return child.loadedNode(for: target)
		}
		return nil
	}

	/// Node for a URL inside this folder, loading the folders on the way (reveal in tree).
	public func node(for target: URL) -> FileNode? {
		let path = target.standardizedFileURL.path
		if path == url.path { return self }
		guard path.hasPrefix(url.path + "/") else { return nil }
		for child in children where path == child.url.path || path.hasPrefix(child.url.path + "/") {
			return child.node(for: target)
		}
		return nil
	}
}
