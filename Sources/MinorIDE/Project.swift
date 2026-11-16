import AppKit
import MinorCore
import SecretsKit

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
	/// Called after the project was trusted or restricted (its windows update the banner).
	var onTrustChange: [() -> Void] = []
	/// Called when the checked-out branch changed (the status bars show it).
	var onGitHeadChange: [() -> Void] = []
	/// The checked-out branch; nil in Restricted Mode or outside a repository.
	private(set) var gitHead: GitHead?
	private var watcher: FileWatcher?
	private let trust: ProjectTrust
	/// Every file of the project, for Open Quickly.
	let paths: PathIndex
	/// Project files used most recently first (relative paths), ranked higher in Open Quickly.
	private(set) var recentFiles: [String] = []

	func noteOpened(_ file: URL) {
		guard let rel = paths.relative(file.standardizedFileURL.path), !rel.isEmpty else { return }
		recentFiles.removeAll { $0 == rel }
		recentFiles.insert(rel, at: 0)
		if recentFiles.count > 50 { recentFiles.removeLast() }
	}

	init(root url: URL, trust: ProjectTrust = ProjectTrust()) {
		root = FileNode(url: url, isDirectory: true)
		self.trust = trust
		isTrusted = trust.isTrusted(url)
		paths = PathIndex(root: url)
		paths.build()
		for file in NSDocumentController.shared.recentDocumentURLs.reversed() where contains(file) { noteOpened(file) }
		watch()
		refreshGitHead()
	}

	/// False = Restricted Mode (D18): nothing from the project may be run. Every feature that
	/// starts a process for the project (Git, gopls, tools, run, debugger) checks this first.
	private(set) var isTrusted: Bool

	func setTrusted(_ trusted: Bool) throws {
		try trust.setTrusted(trusted, url)
		isTrusted = trusted
		for handler in onTrustChange { handler() }
		refreshGitHead()
	}

	/// Re-reads `HEAD` (only the file, no Git process). Called on start, trust change, window
	/// activation and when FSEvents reports a `HEAD` in the project.
	func refreshGitHead() {
		let head = isTrusted ? GitHead.read(for: url) : nil
		guard head != gitHead else { return }
		gitHead = head
		for handler in onGitHeadChange { handler() }
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
		self.paths.update(changed: paths)
		if paths.contains(where: { $0.hasSuffix("/HEAD") }) { refreshGitHead() }
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
	/// The shell in the bottom panel, started when the first tab shows it.
	private(set) lazy var terminal = ProjectTerminal(project: self)
	private var hasTerminal = false
	func makeTerminal() -> ProjectTerminal {
		hasTerminal = true
		return terminal
	}

	/// Find in Project, shared by the project's tabs like the terminal.
	private(set) lazy var findInFiles = FindInFiles(project: self)

	func close() {
		if hasTerminal { terminal.stop() }
		watcher?.stop()
		watcher = nil
	}
}
