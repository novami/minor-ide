import Foundation
import L10nKit

// minoride-l10n: `generate` writes the typed accessors, `validate` checks all language files (docs/LOCALIZATION.md).
// Run from the repository root (tools/l10n.sh generate | validate).

let resources = URL(fileURLWithPath: "Resources/Localization")
let output = URL(fileURLWithPath: "Core/Localization/Generated/Strings.swift")
let sources = URL(fileURLWithPath: ".")

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
case "bundle":
	// Copies the language files into the app's Resources and writes one <lang>.lproj per language
	// (system UI follows it) with InfoPlist.strings from the infoPlist namespace. Prints the lproj names.
	guard arguments.count == 2, let target = arguments.last.map(URL.init(fileURLWithPath:)) else { fail(["usage: minoride-l10n bundle <app Resources folder>"]) }
	do { try bundle(into: target) } catch { fail(["\(error)"]) }
default:
	fail(["usage: minoride-l10n generate | validate [--require <locale>…] | bundle <folder>"])
}

func bundle(into target: URL) throws {
	let fm = FileManager.default
	let files = try fm.contentsOfDirectory(at: resources, includingPropertiesForKeys: nil).filter { $0.pathExtension == "json" }
	let catalogs = try files.map { try Catalog(data: Data(contentsOf: $0)) }
	let english = catalogs.first { $0.meta.locale == "en-US" }
	let folder = target.appendingPathComponent("Localization")
	try fm.createDirectory(at: folder, withIntermediateDirectories: true)
	for file in files {
		let destination = folder.appendingPathComponent(file.lastPathComponent)
		try? fm.removeItem(at: destination)
		try fm.copyItem(at: file, to: destination)
	}
	let languages = catalogs.map { String($0.meta.locale.split(separator: "-").first ?? "") }
	var names: [String] = []
	for catalog in catalogs {
		let language = String(catalog.meta.locale.split(separator: "-").first ?? "")
		let name = languages.filter { $0 == language }.count > 1 ? catalog.meta.locale : language
		names.append(name)
		let lproj = target.appendingPathComponent(name + ".lproj")
		try fm.createDirectory(at: lproj, withIntermediateDirectories: true)
		var lines: [String] = []
		let keys = Set((english?.messages.keys ?? catalog.messages.keys).filter { $0.hasPrefix("infoPlist.") })
		for key in keys.sorted() {
			guard let template = (catalog.messages[key] ?? english?.messages[key])?.text else { continue }
			let text = template.segments.map { if case .literal(let s) = $0 { s } else { "" } }.joined()
			let quoted = text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
			lines.append("\"\(key.dropFirst("infoPlist.".count))\" = \"\(quoted)\";")
		}
		if !lines.isEmpty {
			try (lines.joined(separator: "\n") + "\n").write(to: lproj.appendingPathComponent("InfoPlist.strings"), atomically: true, encoding: .utf8)
		}
	}
	print(names.sorted().joined(separator: " "))
}
