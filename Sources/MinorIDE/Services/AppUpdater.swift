import AppKit
import Foundation
import MinorCore
import UpdateKit

/// The app's update controller. The feed URL (https) and the Ed25519 public key (base64) come from
/// Info.plist (`MIUpdateFeedURL`, `MIUpdatePublicKey`, set by tools/bundle.sh from the release
/// environment). Without them updates are reported as not set up and nothing is contacted.
@MainActor
enum AppUpdater {
	static let shared: UpdateController = {
		let info = Bundle.main.infoDictionary ?? [:]
		let feed = (info["MIUpdateFeedURL"] as? String).flatMap(URL.init(string:))
		let key = (info["MIUpdatePublicKey"] as? String).flatMap { Data(base64Encoded: $0) } ?? Data()
		let version = info["CFBundleShortVersionString"] as? String ?? "0.0.0"
		return UpdateController(appID: Bundle.main.bundleIdentifier ?? "cz.novami.minor.ide", currentVersion: version, feedURL: feed, publicKey: key,
		                        preferences: preferences(SettingsFile.load(SettingsFile.userURL)), transport: URLSessionTransport())
	}()

	static func preferences(_ file: SettingsFile?) -> UpdatePreferences {
		UpdatePreferences(autoCheck: file?.autoCheckUpdates ?? true, autoDownload: file?.autoDownloadUpdates ?? true)
	}

	/// Installs the verified update over the running bundle and starts the new copy. Only for an app
	/// bundle (a development build run from .build is not replaced).
	static func installAndRestart() {
		let app = Bundle.main.bundleURL
		guard app.pathExtension == "app", shared.install(currentApp: app) else { return }
		let relaunch = Process()
		relaunch.executableURL = URL(fileURLWithPath: "/bin/sh")
		relaunch.arguments = ["-c", "sleep 1; exec /usr/bin/open -n \"$1\"", "sh", app.path] // fixed script, the path is an argument
		try? relaunch.run()
		NSApp.terminate(nil)
	}

	/// Called at launch and whenever settings.json changes.
	static func reloadPreferences() {
		shared.preferences = preferences(SettingsFile.load(SettingsFile.userURL))
	}
}
