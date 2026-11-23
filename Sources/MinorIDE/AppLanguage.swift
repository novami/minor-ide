import Foundation
import Localization

/// Loads the UI language once at startup (docs/LOCALIZATION.md).
enum AppLanguage {
	/// Language files in the app bundle; nil outside the bundle (swift run), where English is used.
	static var directory: URL? {
		Bundle.main.resourceURL.map { $0.appendingPathComponent("Localization") }
			.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
	}

	/// Locale codes of the bundled language files.
	static func available() -> [String] {
		guard let directory, let files = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return ["en-US"] }
		return files.filter { $0.hasSuffix(".json") }.map { String($0.dropLast(5)) }.sorted()
	}

	static func start() {
		guard let directory else { return }
		L10n.current = Localizer.load(language: L10n.resolve(preference: nil, available: available()), directory: directory)
	}
}
