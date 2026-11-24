import CryptoKit
import Foundation

/// Copies of files taken when they are saved (File › Local History), kept outside projects
/// for `keepDays` days. One folder per file path (SHA-256 of the path, the path itself in
/// `path`), one file per version named by its time in milliseconds. Only the user can read
/// them: saved files may hold secrets.
nonisolated public struct LocalHistory: Sendable {
	public struct Version: Sendable, Equatable {
		public let date: Date
		public let url: URL
		public let size: Int
	}

	public static let keepDays = 14
	/// Larger files are not copied (the same limit as the simplified editor mode).
	public static let maxFileSize = 5 * 1024 * 1024

	public let root: URL

	public init(root: URL = LocalHistory.defaultRoot) { self.root = root }

	public static var defaultRoot: URL {
		FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/MinorIDE/History")
	}

	private func folder(for path: String) -> URL {
		let digest = SHA256.hash(data: Data(path.utf8)).map { String(format: "%02x", $0) }.joined()
		return root.appendingPathComponent(digest)
	}

	/// Stores `data` as a version of `path`, unless it is too large or equals the newest one.
	public func record(_ data: Data, for path: String, date: Date = Date()) throws {
		guard data.count <= Self.maxFileSize else { return }
		if let newest = versions(of: path).first, (try? Data(contentsOf: newest.url)) == data { return }
		let fm = FileManager.default
		let dir = folder(for: path)
		try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
		try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
		let pathFile = dir.appendingPathComponent("path")
		if !fm.fileExists(atPath: pathFile.path) { try Data(path.utf8).write(to: pathFile) }
		var millis = Int64((date.timeIntervalSince1970 * 1000).rounded(.down))
		while fm.fileExists(atPath: dir.appendingPathComponent("\(millis).snap").path) { millis += 1 }
		let file = dir.appendingPathComponent("\(millis).snap")
		guard fm.createFile(atPath: file.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
			throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: file.path])
		}
	}

	/// Versions of `path`, newest first.
	public func versions(of path: String) -> [Version] {
		let dir = folder(for: path)
		let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
		return names.compactMap { name -> Version? in
			guard name.hasSuffix(".snap"), let millis = Int64(name.dropLast(5)) else { return nil }
			let url = dir.appendingPathComponent(name)
			let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
			return Version(date: Date(timeIntervalSince1970: Double(millis) / 1000), url: url, size: size)
		}.sorted { $0.date > $1.date }
	}

	/// Removes versions older than `keepDays` and folders left without versions.
	public func prune(now: Date = Date()) {
		let fm = FileManager.default
		let limit = now.addingTimeInterval(-Double(Self.keepDays) * 86_400)
		for dir in (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] {
			guard let path = try? String(contentsOf: dir.appendingPathComponent("path"), encoding: .utf8) else { continue }
			let all = versions(of: path)
			for version in all where version.date < limit { try? fm.removeItem(at: version.url) }
			if all.allSatisfy({ $0.date < limit }) { try? fm.removeItem(at: dir) }
		}
	}
}
