import AppKit

/// The UI language: loaded once at startup, chosen in Settings › General (CONTRIBUTING.md).
@MainActor
enum AppLanguage {
	/// Language files in the app bundle; nil outside the bundle (swift run), where English is used.
	nonisolated static var directory: URL? {
		Bundle.main.resourceURL.map { $0.appendingPathComponent("Localization") }
			.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
	}

	/// Bundled languages: locale code and the language's own name, sorted by name.
	static let choices: [(code: String, name: String)] = {
		guard let directory, let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
			return [("en-US", "English")]
		}
		return files.filter { $0.pathExtension == "json" }
			.compactMap { url in (try? Catalog(data: Data(contentsOf: url))).map { ($0.meta.locale, $0.meta.name) } }
			.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
	}()

	/// The preference in settings.json; nil follows the system.
	static func preference(_ file: SettingsFile?) -> String? {
		file?.language.flatMap { $0 == "system" ? nil : $0 }
	}

	/// Set while this app's AppleLanguages was written by the app, not by System Settings
	/// (Language & Region › Applications), which must be kept.
	private static let wroteKey = "AppleLanguagesSetBySettings"

	/// System languages: `-AppleLanguages` on the command line or the per-app choice in System Settings,
	/// else the user's global order (not the AppleLanguages the app wrote itself).
	static func systemLanguages() -> [String] {
		if UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)["AppleLanguages"] != nil
			|| (UserDefaults.standard.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "")?["AppleLanguages"] != nil
				&& !UserDefaults.standard.bool(forKey: wroteKey)) {
			return Locale.preferredLanguages
		}
		let global = CFPreferencesCopyValue("AppleLanguages" as CFString, kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
		return global as? [String] ?? Locale.preferredLanguages
	}

	static func resolve(_ preference: String?) -> String {
		L10n.resolve(preference: preference, available: choices.map(\.code), preferred: systemLanguages())
	}

	static func start() {
		let preference = preference(SettingsFile.load(SettingsFile.userURL))
		syncSystemLanguage(preference)
		guard let directory else { return }
		L10n.current = Localizer.load(language: resolve(preference), directory: directory)
	}

	/// System-provided UI (standard menu items, open and save panels) follows this app's AppleLanguages
	/// from the next launch on.
	static func syncSystemLanguage(_ preference: String?) {
		let defaults = UserDefaults.standard
		if let preference {
			defaults.set([resolve(preference)], forKey: "AppleLanguages")
			defaults.set(true, forKey: wroteKey)
		} else if defaults.bool(forKey: wroteKey) {
			defaults.removeObject(forKey: "AppleLanguages")
			defaults.removeObject(forKey: wroteKey)
		}
	}

	/// After a change in Settings: offers to restart when the running language differs.
	static func changed(to preference: String?, in window: NSWindow?) {
		syncSystemLanguage(preference)
		guard resolve(preference) != L10n.current.language, let window else { return }
		let alert = NSAlert()
		alert.messageText = Strings.settings.restartQuestion
		alert.informativeText = Strings.settings.restartInfo
		alert.addButton(withTitle: Strings.settings.restartNow)
		alert.addButton(withTitle: Strings.settings.later)
		alert.beginSheetModal(for: window) { response in
			if response == .alertFirstButtonReturn { (NSApp.delegate as? AppDelegate)?.restart() }
		}
	}
}
