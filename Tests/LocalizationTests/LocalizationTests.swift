import Foundation
import XCTest
@testable import MinorIDE

final class PluralRuleTests: XCTestCase {
	let czech = try! PluralRules(["one": "i = 1 and v = 0", "few": "i = 2..4 and v = 0", "many": "v != 0"])

	func testCzechCategories() throws {
		XCTAssertEqual(czech.category(PluralOperands(1)), .one)
		XCTAssertEqual(czech.category(PluralOperands(3)), .few)
		XCTAssertEqual(czech.category(PluralOperands(5)), .other)
		XCTAssertEqual(czech.category(PluralOperands(0)), .other)
		XCTAssertEqual(czech.category(PluralOperands(1.5)), .many)
		XCTAssertEqual(czech.category(try XCTUnwrap(PluralOperands(decimal: "1.0"))), .many)
	}

	func testModuloListsAndSamples() throws {
		// Russian "few", with a sample list that must be ignored.
		let rule = try PluralRule("v = 0 and i % 10 = 2..4 and i % 100 != 12..14 @integer 2~4, 22~24")
		XCTAssertTrue(rule.matches(PluralOperands(22)))
		XCTAssertFalse(rule.matches(PluralOperands(12)))
		try XCTAssertTrue(PluralRule("n = 0,1 or n = 11..99").matches(PluralOperands(42)))
		XCTAssertThrowsError(try PluralRule("i = = 1"))
		XCTAssertThrowsError(try PluralRule("x = 1"))
	}
}

final class LocalizerTests: XCTestCase {
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

	func testTextsPluralsVariantsAndFormats() throws {
		let l = try localizer()
		XCTAssertEqual(l.string("project.delete.confirmation", ["projectName": .text("Web")]), "Smazat projekt „Web“?")
		XCTAssertEqual(l.string("files.selected", count: 1), "Vybrán 1 soubor")
		XCTAssertEqual(l.string("files.selected", count: 3), "Vybrány 3 soubory")
		XCTAssertEqual(l.string("files.selected", count: 12), "Vybráno 12 souborů")
		XCTAssertEqual(l.string("docker.container", variant: "genitive"), "kontejneru")
		XCTAssertEqual(l.string("docker.container"), "kontejner")
		XCTAssertTrue(l.string("size", ["size": .integer(2_000_000)]).hasSuffix("MB, {doslova}"))
	}

	func testMissingTranslationIsMarkedInDebug() throws {
		try XCTAssertEqual(localizer().string("only.english"), "⟦only.english⟧")
		try XCTAssertEqual(localizer().string("no.such.key"), "⟦no.such.key⟧")
	}

	func testCatalogReportsProblemsAndParserReportsDuplicates() throws {
		let source = #"{ "$meta": { "locale": "de-DE" }, "a": { "b": "x {broken" }, "c": "1", "c": "2" }"#
		let parsed = try JSONTreeParser.parse(Data(source.utf8))
		XCTAssertEqual(parsed.duplicates.map(\.path), ["c"])
		let catalog = try Catalog(tree: parsed.tree)
		XCTAssertEqual(catalog.problems.count, 1)
		XCTAssertEqual(catalog.messages["a.b"]?.text?.segments, [.literal("x {broken")])
	}

	func testLanguageResolution() {
		let available = ["cs-CZ", "en-US", "pt-BR"]
		XCTAssertEqual(L10n.resolve(preference: nil, available: available, preferred: ["cs", "en"]), "cs-CZ")
		XCTAssertEqual(L10n.resolve(preference: "system", available: available, preferred: ["de-DE", "pt-PT"]), "pt-BR")
		XCTAssertEqual(L10n.resolve(preference: "en-US", available: available, preferred: ["cs-CZ"]), "en-US")
		XCTAssertEqual(L10n.resolve(preference: nil, available: available, preferred: ["ja"]), "en-US")
	}
}

final class ToolingTests: XCTestCase {
	/// The real language files: Czech complete, no unused or missing keys (CI gate, was `make l10n-check`).
	func testShippedLanguageFilesAreValid() {
		let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
		let report = Validator(directory: root.appendingPathComponent("Resources/Localization"),
		                       sources: root, required: ["cs-CZ"]).run()
		XCTAssertTrue(report.errors.isEmpty, report.errors.joined(separator: "\n"))
	}


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

	func testGeneratesTypedAccessors() throws {
		let code = Generator.swift(source: Self.english, catalog: try Catalog(data: Data(Self.english.utf8)))
		XCTAssertTrue(code.contains("/// Status bar.\n\t\tpublic static func selected(count: Int) -> String { L10n.string(\"files.selected\", count: count) }"))
		XCTAssertTrue(code.contains("public static func `open`(path: some CustomStringConvertible, date: Date) -> String"))
		XCTAssertTrue(code.contains("public enum ContainerVariant: String, Sendable { case genitive }"))
		XCTAssertTrue(code.contains("public static var `default`: String { L10n.string(\"default\") }"))
	}

	func testValidatorFindsProblems() throws {
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
		for text in expected { XCTAssertTrue(report.errors.contains { $0.contains(text) }, "\(text)") }
		XCTAssertEqual(report.completeness.first?.done, 0)
	}
}
