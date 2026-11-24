import Foundation

/// Checks the language files against the source language and the code (docs/LOCALIZATION.md).
nonisolated public struct Validator {
	public struct Report {
		public var errors: [String] = []
		public var warnings: [String] = []
		/// Per language: translated messages of all source messages.
		public var completeness: [(language: String, done: Int, total: Int)] = []
		public init() {}
	}

	public let directory: URL
	public let sources: URL?
	public let required: Set<String>
	public let sourceLanguage = "en-US"

	public init(directory: URL, sources: URL?, required: Set<String>) {
		self.directory = directory
		self.sources = sources
		self.required = required
	}

	/// Reads one language file; errors go to `report` with the file name.
	public static func read(_ url: URL, into report: inout Report) -> (source: String, catalog: Catalog)? {
		let file = url.lastPathComponent
		guard let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) else {
			report.errors.append("\(file): cannot be read as UTF-8")
			return nil
		}
		do {
			let parsed = try JSONTreeParser.parse(data)
			for d in parsed.duplicates { report.errors.append("\(file):\(d.line): duplicate key \(d.path)") }
			let catalog = try Catalog(tree: parsed.tree)
			for p in catalog.problems { report.errors.append("\(file): \(p)") }
			var missingMeta = [String]()
			if catalog.meta.name.isEmpty { missingMeta.append("name") }
			if catalog.meta.englishName.isEmpty { missingMeta.append("englishName") }
			if parsed.tree["$meta"]?["plural"] == nil { missingMeta.append("plural") }
			for field in missingMeta { report.errors.append("\(file): $meta.\(field) is missing") }
			if catalog.meta.locale + ".json" != file { report.errors.append("\(file): $meta.locale is \(catalog.meta.locale)") }
			for key in catalog.messages.keys.sorted() where !key.split(separator: ".").allSatisfy({ Generator.isValidSegment(String($0)) }) {
				report.errors.append("\(file): key \(key) is not a valid name (letters, digits and _ between dots)")
			}
			for key in catalog.messages.keys.sorted() where key.split(separator: ".").contains(where: { reserved.contains(String($0)) }) {
				report.errors.append("\(file): key \(key) uses a reserved name (text, note, variants or a plural category)")
			}
			return (text, catalog)
		} catch {
			report.errors.append("\(file): \(error)")
			return nil
		}
	}

	/// Names that mark a message object; a namespace cannot contain them as keys.
	static let reserved: Set<String> = Set(["text", "note", "variants"] + PluralCategory.allCases.map(\.rawValue))

	public func run() -> Report {
		var report = Report()
		let files = ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
			.filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
		guard let sourceURL = files.first(where: { $0.lastPathComponent == sourceLanguage + ".json" }),
		      let (sourceText, source) = Self.read(sourceURL, into: &report) else {
			report.errors.append("\(sourceLanguage).json is missing or invalid")
			return report
		}
		if sourceText.contains("\"\"\"#") { report.errors.append("\(sourceLanguage).json: must not contain \"\"\"#") }
		checkNames(source, into: &report)
		if let sources { checkUsage(source, sources: sources, into: &report) }

		for url in files where url != sourceURL {
			guard let (_, catalog) = Self.read(url, into: &report) else { continue }
			let done = compare(catalog, with: source, into: &report)
			report.completeness.append((catalog.meta.locale, done, source.messages.count))
		}
		for language in required where !report.completeness.contains(where: { $0.language == language }) {
			report.errors.append("\(language).json is required but missing")
		}
		return report
	}

	/// A message and a namespace with the same path cannot both exist (the generated code would clash).
	private func checkNames(_ source: Catalog, into report: inout Report) {
		let keys = Set(source.messages.keys)
		for key in keys.sorted() {
			var prefix = ""
			for part in key.split(separator: ".").dropLast() {
				prefix += (prefix.isEmpty ? "" : ".") + part
				if keys.contains(prefix) { report.errors.append("en-US.json: \(prefix) is both a message and a namespace of \(key)") }
			}
		}
		for (key, message) in source.messages where message.text == nil && !message.isPlural {
			report.errors.append("en-US.json: \(key) has no text")
		}
	}

	/// Every message must be used as `Strings.<key>` somewhere in the code.
	private func checkUsage(_ source: Catalog, sources: URL, into report: inout Report) {
		var used = Set<String>()
		let pattern = /Strings((?:\.[A-Za-z_][A-Za-z0-9_]*)+)/
		let enumerator = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)
		while let url = enumerator?.nextObject() as? URL {
			guard url.pathExtension == "swift", !url.path.contains("/Generated/"), !url.path.contains("/.build/"),
			      let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
			for match in text.matches(of: pattern) { used.insert(String(match.output.1.dropFirst())) }
		}
		// infoPlist.* goes into InfoPlist.strings, not into the code.
		for key in source.messages.keys.sorted() where !key.hasPrefix("infoPlist.") && !used.contains(where: { $0 == key || $0.hasPrefix(key + ".") }) {
			report.errors.append("en-US.json: \(key) is not used in the code")
		}
	}

	/// Compares one translation with the source and returns the number of translated messages.
	private func compare(_ catalog: Catalog, with source: Catalog, into report: inout Report) -> Int {
		let file = catalog.meta.locale + ".json"
		let isRequired = required.contains(catalog.meta.locale)
		var done = 0
		let produced = Set(catalog.pluralRules.rules.map(\.0)).union([.other])
		for key in catalog.messages.keys.sorted() where source.messages[key] == nil {
			report.errors.append("\(file): \(key) is not in en-US.json")
		}
		for key in source.messages.keys.sorted() {
			guard let original = source.messages[key] else { continue }
			guard let message = catalog.messages[key] else {
				if isRequired { report.errors.append("\(file): \(key) is not translated") }
				else { report.warnings.append("\(file): \(key) is not translated") }
				continue
			}
			var ok = true
			func fail(_ text: String) { report.errors.append("\(file):\(message.line): \(key): \(text)"); ok = false }
			if original.isPlural != message.isPlural { fail(original.isPlural ? "must have plural forms" : "must not have plural forms") }
			if message.isPlural {
				if message.plural[.other] == nil { fail("the plural form \"other\" is missing") }
				for c in PluralCategory.allCases where message.plural[c] != nil && !produced.contains(c) {
					fail("the plural form \"\(c.rawValue)\" never applies in \(catalog.meta.locale)")
				}
				for c in produced where message.plural[c] == nil { fail("the plural form \"\(c.rawValue)\" is missing") }
			}
			for v in original.variants.keys.sorted() where message.variants[v] == nil { fail("the variant \"\(v)\" is missing") }
			for v in message.variants.keys.sorted() where original.variants[v] == nil { fail("the variant \"\(v)\" is not in en-US.json") }

			let expected = Self.parameters(original)
			let actual = Self.parameters(message)
			for (name, format) in expected.sorted(by: { $0.key < $1.key }) {
				if let f = actual[name], f != format { fail("{\(name)} must have the format \"\(format)\"") }
				else if actual[name] == nil, !(name == "count" && original.isPlural) { fail("{\(name)} is missing") }
			}
			for name in actual.keys.sorted() where expected[name] == nil { fail("{\(name)} is not in en-US.json") }
			if ok { done += 1 }
		}
		return done
	}

	private static func parameters(_ message: Message) -> [String: ParameterFormat] {
		var out: [String: ParameterFormat] = [:]
		for t in message.templates { for p in t.parameters { out[p.name] = p.format } }
		return out
	}
}
