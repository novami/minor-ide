import Foundation
import Testing
@testable import Localization
@testable import L10nTooling

struct PluralRuleTests {
	let czech = try! PluralRules(["one": "i = 1 and v = 0", "few": "i = 2..4 and v = 0", "many": "v != 0"])

	@Test func czechCategories() throws {
		#expect(czech.category(PluralOperands(1)) == .one)
		#expect(czech.category(PluralOperands(3)) == .few)
		#expect(czech.category(PluralOperands(5)) == .other)
		#expect(czech.category(PluralOperands(0)) == .other)
		#expect(czech.category(PluralOperands(1.5)) == .many)
		#expect(czech.category(try #require(PluralOperands(decimal: "1.0"))) == .many)
	}

	@Test func moduloListsAndSamples() throws {
		// Russian "few", with a sample list that must be ignored.
		let rule = try PluralRule("v = 0 and i % 10 = 2..4 and i % 100 != 12..14 @integer 2~4, 22~24")
		#expect(rule.matches(PluralOperands(22)))
		#expect(!rule.matches(PluralOperands(12)))
		#expect(try PluralRule("n = 0,1 or n = 11..99").matches(PluralOperands(42)))
		#expect(throws: PluralRuleError.self) { try PluralRule("i = = 1") }
		#expect(throws: PluralRuleError.self) { try PluralRule("x = 1") }
	}
}

struct LocalizerTests {
	static let czechFile = #"""
	{
		"$meta": { "locale": "cs-CZ", "name": "Čeština", "englishName": "Czech", "fallback": "en-US",
			"plural": { "one": "i = 1 and v = 0", "few": "i = 2..4 and v = 0", "many": "v != 0" } },
		"project": { "delete": { "confirmation": { "text": "Smazat projekt „{projectName}“?" } } },
		"files": { "selected": { "one": "Vybrán {count} soubor", "few": "Vybrány {count} soubory", "many": "Vybráno {count} souboru", "other": "Vybráno {count} souborů" } },
		"docker": { "container": { "text": "kontejner", "variants": { "genitive": "kontejneru" } } },
		"size": "Velikost {size, bytes}, {{doslova}}"
	}
	"""#

	static let englishFile = #"""
	{
		"$meta": { "locale": "en-US", "plural": { "one": "i = 1 and v = 0" } },
		"files": { "selected": { "one": "{count} file selected", "other": "{count} files selected" } },
		"only": { "english": "Only in English" }
	}
	"""#

	func localizer() throws -> Localizer {
		Localizer(chain: [try Catalog(data: Data(Self.czechFile.utf8)), try Catalog(data: Data(Self.englishFile.utf8))])
	}

	@Test func textsPluralsVariantsAndFormats() throws {
		let l = try localizer()
		#expect(l.string("project.delete.confirmation", ["projectName": .text("Web")]) == "Smazat projekt „Web“?")
		#expect(l.string("files.selected", count: 1) == "Vybrán 1 soubor")
		#expect(l.string("files.selected", count: 3) == "Vybrány 3 soubory")
		#expect(l.string("files.selected", count: 12) == "Vybráno 12 souborů")
		#expect(l.string("docker.container", variant: "genitive") == "kontejneru")
		#expect(l.string("docker.container") == "kontejner")
		#expect(l.string("size", ["size": .integer(2_000_000)]).hasSuffix("MB, {doslova}"))
	}

	@Test func missingTranslationIsMarkedInDebug() throws {
		#expect(try localizer().string("only.english") == "⟦only.english⟧")
		#expect(try localizer().string("no.such.key") == "⟦no.such.key⟧")
	}

	@Test func catalogReportsProblemsAndParserReportsDuplicates() throws {
		let source = #"{ "$meta": { "locale": "de-DE" }, "a": { "b": "x {broken" }, "c": "1", "c": "2" }"#
		let parsed = try JSONTreeParser.parse(Data(source.utf8))
		#expect(parsed.duplicates.map(\.path) == ["c"])
		let catalog = try Catalog(tree: parsed.tree)
		#expect(catalog.problems.count == 1)
		#expect(catalog.messages["a.b"]?.text?.segments == [.literal("x {broken")])
	}

	@Test func languageResolution() {
		let available = ["cs-CZ", "en-US", "pt-BR"]
		#expect(L10n.resolve(preference: nil, available: available, preferred: ["cs", "en"]) == "cs-CZ")
		#expect(L10n.resolve(preference: "system", available: available, preferred: ["de-DE", "pt-PT"]) == "pt-BR")
		#expect(L10n.resolve(preference: "en-US", available: available, preferred: ["cs-CZ"]) == "en-US")
		#expect(L10n.resolve(preference: nil, available: available, preferred: ["ja"]) == "en-US")
	}
}

struct ToolingTests {
	func write(_ files: [String: String]) throws -> URL {
		let dir = FileManager.default.temporaryDirectory.appendingPathComponent("L10nTests-\(UUID().uuidString)")
		try FileManager.default.createDirectory(at: dir.appendingPathComponent("Sources"), withIntermediateDirectories: true)
		for (name, text) in files { try text.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8) }
		return dir
	}

	static let english = #"""
	{
		"$meta": { "locale": "en-US", "name": "English", "englishName": "English", "plural": { "one": "i = 1 and v = 0" } },
		"files": {
			"selected": { "note": "Status bar.", "one": "{count} file selected", "other": "{count} files selected" },
			"open": "Open {path} at {date, date:short}"
		},
		"docker": { "container": { "text": "container", "variants": { "genitive": "container" } } },
		"default": "Default"
	}
	"""#

	@Test func generatesTypedAccessors() throws {
		let code = Generator.swift(source: Self.english, catalog: try Catalog(data: Data(Self.english.utf8)))
		#expect(code.contains("/// Status bar.\n\t\tpublic static func selected(count: Int) -> String { L10n.string(\"files.selected\", count: count) }"))
		#expect(code.contains("public static func `open`(path: some CustomStringConvertible, date: Date) -> String"))
		#expect(code.contains("public enum ContainerVariant: String, Sendable { case genitive }"))
		#expect(code.contains("public static var `default`: String { L10n.string(\"default\") }"))
	}

	@Test func validatorFindsProblems() throws {
		let czech = #"""
		{
			"$meta": { "locale": "cs-CZ", "name": "Čeština", "englishName": "Czech",
				"plural": { "one": "i = 1 and v = 0", "few": "i = 2..4 and v = 0", "many": "v != 0" } },
			"files": {
				"selected": { "one": "Vybrán {count} soubor", "two": "x", "other": "Vybráno {count} souborů" },
				"open": "Otevřít {path} {date}",
				"extra": "Navíc"
			},
			"docker": { "container": "kontejner" }
		}
		"""#
		let dir = try write(["en-US.json": Self.english, "cs-CZ.json": czech, "Sources/a.swift": "_ = Strings.files.selected(count: 1) + Strings.files.open"])
		defer { try? FileManager.default.removeItem(at: dir) }
		let report = Validator(directory: dir, sources: dir.appendingPathComponent("Sources"), required: ["cs-CZ"]).run()
		let expected = [
			"\"two\" never applies", "\"few\" is missing", "\"many\" is missing", "{date} must have the format \"date:short\"",
			"files.extra is not in en-US.json", "variant \"genitive\" is missing", "default is not translated", "docker.container is not used",
		]
		for text in expected { #expect(report.errors.contains { $0.contains(text) }, "\(text)") }
		#expect(report.completeness.first?.done == 0)
	}
}
