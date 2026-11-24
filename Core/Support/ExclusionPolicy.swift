import Foundation

/// What project walkers (file catalog, Find in Files) never read. Shared so that every consumer
/// sees the same files; `.gitignore` rules come on top (`GitIgnoreSet`).
nonisolated public enum ExclusionPolicy {
	/// Version control internals and Finder metadata: never read, never shown.
	public static func neverRead(_ name: String) -> Bool { FileNode.hiddenNames.contains(name) }

	/// Folders ignored by Git that are not worth reading: hidden ones (build output, tool
	/// caches) and JavaScript packages.
	public static func skipsIgnoredFolder(_ name: String) -> Bool { name.hasPrefix(".") || name == "node_modules" }
}
