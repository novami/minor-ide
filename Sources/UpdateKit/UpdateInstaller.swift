import Foundation

/// Replaces the installed app bundle with the one from a verified archive, with rollback.
/// The archive must already have passed `UpdateVerifier`; this adds checks of the bundle itself.
public enum UpdateInstaller {
	public enum Failure: Error, Equatable {
		case unzipFailed, noApp, wrongApp, notNewer, badCodeSignature, swapFailed
	}

	/// - Parameters:
	///   - currentApp: the running bundle (e.g. /Applications/MinorIDE.app), replaced in place.
	///   - checkCodeSignature: `codesign --verify --deep --strict` on the new bundle; off only in tests.
	public static func install(archive: URL, info: UpdateInfo, appID: String, currentVersion: String,
	                           currentApp: URL, checkCodeSignature: Bool = true) throws {
		let fm = FileManager.default
		guard let new = AppVersion(info.version), let old = AppVersion(currentVersion), old < new else { throw Failure.notNewer }

		let work = fm.temporaryDirectory.appendingPathComponent("minoride-install-\(UUID().uuidString)")
		try fm.createDirectory(at: work, withIntermediateDirectories: true)
		defer { try? fm.removeItem(at: work) }

		guard run("/usr/bin/ditto", ["-x", "-k", archive.path, work.path]) else { throw Failure.unzipFailed }
		let apps = ((try? fm.contentsOfDirectory(at: work, includingPropertiesForKeys: nil)) ?? []).filter { $0.pathExtension == "app" }
		guard apps.count == 1, let fresh = apps.first else { throw Failure.noApp }

		let plist = (NSDictionary(contentsOf: fresh.appendingPathComponent("Contents/Info.plist")) as? [String: Any]) ?? [:]
		guard plist["CFBundleIdentifier"] as? String == appID, plist["CFBundleShortVersionString"] as? String == info.version else {
			throw Failure.wrongApp
		}
		if checkCodeSignature, !run("/usr/bin/codesign", ["--verify", "--deep", "--strict", fresh.path]) { throw Failure.badCodeSignature }

		let backup = currentApp.deletingLastPathComponent().appendingPathComponent(".\(currentApp.lastPathComponent).old-\(UUID().uuidString)")
		do {
			try fm.moveItem(at: currentApp, to: backup)
		} catch { throw Failure.swapFailed }
		do {
			try fm.moveItem(at: fresh, to: currentApp)
		} catch {
			try? fm.moveItem(at: backup, to: currentApp) // roll back
			throw Failure.swapFailed
		}
		try? fm.removeItem(at: backup)
	}

	private static func run(_ tool: String, _ arguments: [String]) -> Bool {
		let process = Process()
		process.executableURL = URL(fileURLWithPath: tool)
		process.arguments = arguments
		process.standardOutput = FileHandle.nullDevice
		process.standardError = FileHandle.nullDevice
		do { try process.run() } catch { return false }
		process.waitUntilExit()
		return process.terminationStatus == 0
	}
}
