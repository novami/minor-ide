import AppKit
import CoreServices
import MinorCore

/// An open folder: the file tree shared by the project's tabs, which folders are expanded,
/// and an FSEvents watch that refreshes loaded folders when files change on disk.
@MainActor
final class Project {
	let root: FileNode
	/// Expanded folders, shared so a new tab shows the tree as the previous one did.
	var expanded: Set<URL> = []
	/// Called with the folders whose children changed (the sidebars reload them).
	var onChange: [(FileNode) -> Void] = []
	/// Called with every changed path (open windows compare their files with the disk).
	var onFiles: (([String]) -> Void)?
	private var stream: FSEventStreamRef?

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
		var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
		let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
			guard let info else { return }
			let project = Unmanaged<Project>.fromOpaque(info).takeUnretainedValue()
			let list = (Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as? [String]) ?? []
			MainActor.assumeIsolated { project.changed(Array(list.prefix(count))) }
		}
		let flags = UInt32(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
		guard let stream = FSEventStreamCreate(nil, callback, &context, [url.path] as CFArray,
		                                       FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.3, flags) else { return }
		FSEventStreamSetDispatchQueue(stream, .main)
		FSEventStreamStart(stream)
		self.stream = stream
	}

	/// Stops the watch; the project must not be used for events afterwards.
	func close() {
		guard let stream else { return }
		FSEventStreamStop(stream)
		FSEventStreamInvalidate(stream)
		FSEventStreamRelease(stream)
		self.stream = nil
	}
}
