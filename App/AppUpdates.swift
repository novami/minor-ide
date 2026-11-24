import MinorUpdater

/// The one updater of the app (checks GitHub Releases, see MinorUpdater).
enum AppUpdates {
	static let updater = Updater()
}
