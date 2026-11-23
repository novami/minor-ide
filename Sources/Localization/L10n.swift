import Foundation
import os

/// Resolves messages of one language with its fallback chain (selected → its fallback … → en-US).
public final class Localizer: Sendable {
	public let language: String
	public let locale: Locale
	/// The selected catalog first, the built-in English last.
	public let chain: [Catalog]

	public init(chain: [Catalog]) {
		self.chain = chain
		language = chain.first?.meta.locale ?? "en-US"
		locale = Locale(identifier: language)
	}

	/// English only (the source texts built into the code).
	public static let english = Localizer(chain: [L10n.englishCatalog])

	/// Loads `<language>.json` and its fallbacks from `directory`. A missing or broken file is skipped
	/// (and logged); the built-in English is always the last step.
	public static func load(language: String, directory: URL) -> Localizer {
		var chain: [Catalog] = []
		var next: String? = language
		var visited = Set<String>()
		while let code = next, code != "en-US", visited.insert(code).inserted {
			let url = directory.appendingPathComponent(code + ".json")
			guard let data = try? Data(contentsOf: url) else { L10n.log.error("language file \(code, privacy: .public).json is missing"); break }
			do {
				let catalog = try Catalog(data: data)
				chain.append(catalog)
				next = catalog.meta.fallback ?? "en-US"
			} catch {
				L10n.log.error("language file \(code, privacy: .public).json: \(String(describing: error), privacy: .public)")
				break
			}
		}
		return Localizer(chain: chain + [L10n.englishCatalog])
	}

	public func string(_ key: String, variant: String? = nil, count: Int? = nil, _ arguments: [String: L10nValue] = [:]) -> String {
		for (index, catalog) in chain.enumerated() {
			guard let message = catalog.messages[key] else { continue }
			let template: Template?
			if let variant {
				template = message.variants[variant]
			} else if message.isPlural {
				let category = catalog.pluralRules.category(PluralOperands(count ?? 0))
				template = message.plural[category] ?? message.plural[.other]
			} else {
				template = message.text
			}
			guard let template else { continue }
			#if DEBUG
			if index > 0, index == chain.count - 1 { return L10n.missing(key, language: language) }
			#endif
			_ = index
			var arguments = arguments
			if let count, arguments["count"] == nil { arguments["count"] = .integer(count) }
			return template.render(arguments, locale: locale)
		}
		return L10n.missing(key, language: language)
	}
}

/// The active language. Set once at startup (`L10n.current = .load(…)`); tests may switch it.
public enum L10n {
	static let log = Logger(subsystem: "MinorIDE", category: "l10n")
	private static let state = OSAllocatedUnfairLock<Localizer?>(initialState: nil)
	private static let reported = OSAllocatedUnfairLock<Set<String>>(initialState: [])

	public static var current: Localizer {
		get { state.withLock { $0 } ?? Localizer.english }
		set { state.withLock { $0 = newValue } }
	}

	/// The English source file built into the code by `minoride-l10n generate`.
	public static let englishCatalog: Catalog = {
		do { return try Catalog(data: Data(englishSource.utf8)) } catch {
			log.fault("built-in English is invalid: \(String(describing: error), privacy: .public)")
			// The generator validates the source first, so this only happens with a hand-edited file.
			return Catalog(empty: "en-US")
		}
	}()

	public static func string(_ key: String, variant: String? = nil, count: Int? = nil, _ arguments: [String: L10nValue] = [:]) -> String {
		current.string(key, variant: variant, count: count, arguments)
	}

	static func missing(_ key: String, language: String) -> String {
		if reported.withLock({ $0.insert(key).inserted }) {
			log.error("missing translation \(key, privacy: .public) in \(language, privacy: .public)")
		}
		return "⟦\(key)⟧"
	}

	/// The language to use: `preference` ("system" or nil means the system order) matched against the
	/// available language codes, first exactly, then by language only; en-US when nothing matches.
	public static func resolve(preference: String?, available: [String], preferred: [String] = Locale.preferredLanguages) -> String {
		func normalized(_ s: String) -> String { s.replacingOccurrences(of: "_", with: "-").lowercased() }
		func base(_ s: String) -> String { String(normalized(s).split(separator: "-").first ?? "") }
		var wanted = preferred
		if let preference, preference != "system" { wanted.insert(preference, at: 0) }
		for code in wanted {
			if let exact = available.first(where: { normalized($0) == normalized(code) }) { return exact }
			if let near = available.first(where: { base($0) == base(code) }) { return near }
		}
		return "en-US"
	}
}
