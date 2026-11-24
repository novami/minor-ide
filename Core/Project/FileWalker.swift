import Foundation

/// Walks a project folder: every file not ignored by Git, folders in sorted order.
nonisolated public enum FileWalker {
	/// Calls `visit` with the '/'-separated path relative to `root` of every file; stops when
	/// `visit` returns false or the task is cancelled.
	static func walk(root: URL, ignore: GitIgnoreSet, visit: (String) -> Bool) {
		let fm = FileManager.default
		func rec(_ rel: String) -> Bool {
			let dir = rel.isEmpty ? root : root.appendingPathComponent(rel)
			guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return true }
			for name in names.sorted() {
				if Task.isCancelled { return false }
				if ExclusionPolicy.neverRead(name) { continue }
				let child = rel.isEmpty ? name : rel + "/" + name
				let url = dir.appendingPathComponent(name)
				guard let v = try? url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]) else { continue }
				var isDir = v.isDirectory == true, isFile = v.isRegularFile == true
				if v.isSymbolicLink == true { // links to folders are not followed (cycles)
					guard let t = try? url.resolvingSymlinksInPath().resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey]) else { continue }
					isDir = false
					isFile = t.isRegularFile == true
				}
				if isDir {
					if !ignore.matches(child, isDirectory: true), !rec(child) { return false }
				} else if isFile, !ignore.matches(child, isDirectory: false) {
					if !visit(child) { return false }
				}
			}
			return true
		}
		_ = rec("")
	}

	/// All files of `root` (relative paths), for tests and the catalog.
	public static func files(in root: URL) -> [String] {
		var out: [String] = []
		walk(root: root, ignore: GitIgnoreSet(root: root)) { out.append($0); return true }
		return out
	}
}
