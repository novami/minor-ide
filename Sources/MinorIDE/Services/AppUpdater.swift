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
		return UpdateController(currentVersion: version, feedURL: feed, publicKey: key,
		                        preferences: preferences(SettingsFile.load(SettingsFile.userURL)), transport: URLSessionTransport())
	}()

	static func preferences(_ file: SettingsFile?) -> UpdatePreferences {
		UpdatePreferences(autoCheck: file?.autoCheckUpdates ?? true, autoDownload: file?.autoDownloadUpdates ?? true)
	}

	/// Called at launch and whenever settings.json changes.
	static func reloadPreferences() {
		shared.preferences = preferences(SettingsFile.load(SettingsFile.userURL))
	}
}
