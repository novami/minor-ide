import Foundation

/// The checked-out branch read straight from `HEAD` (no Git process).
public enum GitHead: Equatable, Sendable {
	case branch(String)
	/// Detached HEAD: the commit hash.
	case detached(String)

	/// Branch name, or the first 7 characters of the hash.
	public var label: String {
		switch self {
		case .branch(let name): name
		case .detached(let hash): String(hash.prefix(7))
		}
	}

	/// Parses the contents of a `HEAD` file.
	public static func parse(_ contents: String) -> GitHead? {
		let line = contents.trimmingCharacters(in: .whitespacesAndNewlines)
		if line.hasPrefix("ref:") {
			let ref = line.dropFirst(4).trimmingCharacters(in: .whitespaces)
			let name = ref.hasPrefix("refs/heads/") ? String(ref.dropFirst(11)) : ref
			return name.isEmpty ? nil : .branch(name)
		}
		let isHash = line.count >= 40 && line.allSatisfy(\.isHexDigit)
		return isHash ? .detached(line) : nil
	}

	/// The Git directory for `folder`: the nearest `.git` in it or above it. A `.git` file
	/// (worktree, submodule) points elsewhere with `gitdir: <path>`.
	public static func gitDirectory(for folder: URL) -> URL? {
		let fm = FileManager.default
		var dir = folder.standardizedFileURL
		while true {
			let git = dir.appendingPathComponent(".git")
			var isDir: ObjCBool = false
			if fm.fileExists(atPath: git.path, isDirectory: &isDir) {
				if isDir.boolValue { return git }
				guard let text = try? String(contentsOf: git, encoding: .utf8),
				      let line = text.split(separator: "\n").first, line.hasPrefix("gitdir:") else { return nil }
				let path = line.dropFirst(7).trimmingCharacters(in: .whitespaces)
				return URL(fileURLWithPath: path, relativeTo: dir).standardizedFileURL
			}
			let parent = dir.deletingLastPathComponent()
			if parent.path == dir.path { return nil }
			dir = parent
		}
	}

	/// The HEAD of the repository containing `folder`, nil outside a repository.
	public static func read(for folder: URL) -> GitHead? {
		guard let dir = gitDirectory(for: folder),
		      let text = try? String(contentsOf: dir.appendingPathComponent("HEAD"), encoding: .utf8) else { return nil }
		return parse(text)
	}
}
