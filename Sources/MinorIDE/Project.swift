import AppKit
import MinorCore

/// An open folder: the file tree shared by the project's tabs, which folders are expanded,
/// and an FSEvents watch that refreshes loaded folders when files change on disk.
@MainActor
final class Project {
	let root: FileNode
	/// Expanded folders, shared so a new tab shows the tree as the previous one did.
	var expanded: Set<URL> = []
	/// The project folder's own row was collapsed.
	var rootCollapsed = false
	/// Called with the folders whose children changed (the sidebars reload them).
	var onChange: [(FileNode) -> Void] = []
	/// Called with every changed path (open windows compare their files with the disk).
	var onFiles: (([String]) -> Void)?
	private var watcher: FileWatcher?

	init(root url: URL) {
		root = FileNode(url: url, isDirectory: true)
		watch()
	}

	var name: String { root.name }
	var url: URL { root.url }

	func contains(_ file: URL) -> Bool {
		let path = file.standardizedFileURL.path
		return path == url.path || path.hasPrefix(url.path + "/")
	}

	/// Re-reads loaded folders that FSEvents reported (or the parents of reported files).
	private func changed(_ paths: [String]) {
		onFiles?(paths)
		var folders: [FileNode] = []
		for path in paths {
			let u = URL(fileURLWithPath: path)
			guard let node = root.loadedNode(for: u) ?? root.loadedNode(for: u.deletingLastPathComponent()) else { continue }
			let folder = node.isDirectory ? node : (node.parent ?? root)
			if folder.isLoaded, !folders.contains(where: { $0 === folder }) { folders.append(folder) }
		}
		for folder in folders where folder.reload() {
			for handler in onChange { handler(folder) }
		}
	}

	private func watch() {
		watcher = FileWatcher(paths: [url.path]) { [weak self] paths in self?.changed(paths) }
	}

	/// Stops the watch; the project must not be used for events afterwards.
	func close() {
		watcher?.stop()
		watcher = nil
	}
}
