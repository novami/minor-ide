import Foundation
import L10nTooling
import Localization

// minoride-l10n: `generate` writes the typed accessors, `validate` checks all language files (docs/LOCALIZATION.md).
// Run from the repository root (make l10n, make l10n-check).

let resources = URL(fileURLWithPath: "Resources/Localization")
let output = URL(fileURLWithPath: "Sources/Localization/Generated/Strings.swift")
let sources = URL(fileURLWithPath: "Sources")

func fail(_ lines: [String]) -> Never {
	for line in lines { FileHandle.standardError.write(Data(("error: " + line + "\n").utf8)) }
	exit(1)
}

func generated() -> String {
	var report = Validator.Report()
	guard let (text, catalog) = Validator.read(resources.appendingPathComponent("en-US.json"), into: &report), report.errors.isEmpty else {
		fail(report.errors.isEmpty ? ["en-US.json cannot be read"] : report.errors)
	}
	return Generator.swift(source: text, catalog: catalog)
}

let arguments = CommandLine.arguments.dropFirst()
switch arguments.first {
case "generate":
	let code = generated()
	if (try? String(contentsOf: output, encoding: .utf8)) != code {
		do { try code.write(to: output, atomically: true, encoding: .utf8) } catch { fail(["\(output.path): \(error)"]) }
		print("wrote \(output.path)")
	}
case "validate":
	let options = Array(arguments.dropFirst())
	let required = Set(options.indices.filter { options[$0] == "--require" && $0 + 1 < options.count }.map { options[$0 + 1] })
	let report = Validator(directory: resources, sources: sources, required: required.isEmpty ? ["cs-CZ"] : required).run()
	var errors = report.errors
	if report.errors.isEmpty, (try? String(contentsOf: output, encoding: .utf8)) != generated() {
		errors.append("\(output.path) is out of date; run make l10n")
	}
	for w in report.warnings { print("warning: " + w) }
	for c in report.completeness {
		let percent = c.total == 0 ? 100 : c.done * 100 / c.total
		print("\(c.language): \(percent) %, \(c.done)/\(c.total)")
	}
	if !errors.isEmpty { fail(errors) }
default:
	fail(["usage: minoride-l10n generate | validate [--require <locale>…]"])
}
