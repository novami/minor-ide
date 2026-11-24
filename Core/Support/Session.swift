import Foundation

/// Windows open when the app quit, reopened at the next launch when macOS keeps windows
/// (System Settings › Desktop & Dock › Close windows when quitting an application, or the
/// opposite with Quit and Keep Windows). Read once and deleted, so a crash never brings
/// back an old session.
nonisolated public struct Session: Codable, Sendable, Equatable {
	public struct Window: Codable, Sendable, Equatable {
		/// Project folder, or nil for a file outside projects.
		public var project: String?
		/// File shown, or nil for a project window without a file.
		public var file: String?

		public init(project: String?, file: String?) {
			self.project = project
			self.file = file
		}
	}

	public var windows: [Window]
	/// The file or project of the window that was in front.
	public var front: String?
	/// Whether the next launch reopens the windows.
	public var restore: Bool

	public init(windows: [Window], front: String?, restore: Bool) {
		self.windows = windows
		self.front = front
		self.restore = restore
	}

	public static var defaultURL: URL {
		FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/MinorIDE/session.json")
	}

	public func save(to url: URL = Session.defaultURL) throws {
		try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
		try JSONEncoder().encode(self).write(to: url, options: .atomic)
	}

	/// The windows to reopen (paths that no longer exist are left out), or nil; the file is
	/// removed either way.
	public static func take(from url: URL = Session.defaultURL) -> Session? {
		defer { try? FileManager.default.removeItem(at: url) }
		guard let data = try? Data(contentsOf: url), var session = try? JSONDecoder().decode(Session.self, from: data),
		      session.restore else { return nil }
		let fm = FileManager.default
		session.windows = session.windows.filter { window in
			[window.project, window.file].compactMap { $0 }.allSatisfy { fm.fileExists(atPath: $0) }
				&& (window.project != nil || window.file != nil)
		}
		return session.windows.isEmpty ? nil : session
	}
}
