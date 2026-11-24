import Foundation
import XCTest
@testable import MinorIDE

final class FormatTests: XCTestCase {
	func resolve(_ path: String, user: SettingsFile? = nil, project: SettingsFile? = nil,
	             editorConfig: [String: String] = [:], detected: DetectedFormat? = nil) -> FormatSettings {
		FormatResolver.resolve(path: path, user: user, project: project, editorConfig: editorConfig, detected: detected).settings
	}

	func testSettingsUpdateKeepsOtherKeys() throws {
		let start = Data(#"{"detect_indent": true, "other": [1], "format": {"go": {"tab_width": 8}}}"#.utf8)
		var data = try SettingsFile.updating(start, section: "php", key: "preset", value: .string("nette"))
		data = try SettingsFile.updating(data, section: "go", key: "tab_width", value: nil)
		data = try SettingsFile.updating(data, section: nil, key: "detect_indent", value: .bool(false))
		let file = try SettingsFile(json: data)
		XCTAssertEqual(file.format, ["php": ["preset": "nette"]])
		XCTAssertEqual(file.detectIndent, false)
		XCTAssertTrue(String(decoding: data, as: UTF8.self).contains(#""other" : ["#))
		XCTAssertTrue(String(decoding: try SettingsFile.updating(nil, section: "*", key: "tab_width", value: .number(4)), as: UTF8.self).contains(#""tab_width" : 4"#))
		XCTAssertThrowsError(try SettingsFile.updating(Data("{oops".utf8), section: nil, key: "a", value: nil))
	}

	func testFindsCharactersTheCharsetCannotStore() {
		XCTAssertNil(TextFile.firstUnencodable("Příliš žluťoučký", charset: .windows1250))
		XCTAssertEqual(TextFile.firstUnencodable("cena 5 € a → šipka", charset: .iso88592), "€")
		XCTAssertNil(TextFile.firstUnencodable("emoji 🙂", charset: .utf8))
	}

	func testBinaryFilesHaveNulBytes() {
		XCTAssertTrue(TextFile.looksBinary(Data([0x89, 0x50, 0x4E, 0x47, 0x00, 0x01])))
		XCTAssertFalse(TextFile.looksBinary(Data("<?php echo 1;".utf8)))
		XCTAssertFalse(TextFile.looksBinary(Data([0xFF, 0xFE, 0x61, 0x00])))
	}

	func testSimplifiedModeForLargeOrMinifiedFiles() {
		XCTAssertFalse(TextFile.needsSimplifiedMode(Data("a\nb".utf8)))
		XCTAssertTrue(TextFile.needsSimplifiedMode(Data(("x\n" + String(repeating: "y", count: 11)).utf8), maxLine: 10))
		XCTAssertTrue(TextFile.needsSimplifiedMode(Data(String(repeating: "z", count: 20).utf8), maxBytes: 10))
	}

	func testStandardDefaults() {
		let php = resolve("/p/src/User.php")
		XCTAssertTrue(php.indentStyle == .space && php.indentSize == 4 && php.lineEnding == .lf)
		XCTAssertTrue(php.insertFinalNewline && php.charset == .utf8 && php.maxLineLength == 120)
		XCTAssertEqual(resolve("/p/main.go").indentStyle, .tab)
		XCTAssertEqual(resolve("/p/app/UI/default.latte").indentStyle, .tab)
		XCTAssertEqual(resolve("/p/config/common.neon").indentStyle, .tab)
		XCTAssertEqual(resolve("/p/a.yaml").indentSize, 2)
		XCTAssertEqual(resolve("/p/package.json").indentSize, 2)
		XCTAssertEqual(resolve("/p/composer.json").indentSize, 4)
		XCTAssertEqual(resolve("/p/Makefile").indentStyle, .tab)
		XCTAssertEqual(resolve("/p/run.bat").lineEnding, .crlf)
		XCTAssertEqual(resolve("/p/README.md").trimTrailingWhitespace, .none)
	}

	func testPrecedence() throws {
		let user = try SettingsFile(json: Data(#"{"format": {"*": {"end_of_line": "crlf"}, "php": {"preset": "nette"}}}"#.utf8))
		var s = resolve("/p/a.php", user: user)
		XCTAssertTrue(s.indentStyle == .tab && s.lineEnding == .crlf)

		let project = try SettingsFile(json: Data(#"{"format": {"php": {"indent_style": "space", "indent_size": 2}}}"#.utf8))
		s = resolve("/p/a.php", user: user, project: project)
		XCTAssertTrue(s.indentStyle == .space && s.indentSize == 2)

		s = resolve("/p/a.php", user: user, project: project, editorConfig: ["indent_size": "4", "end_of_line": "lf"])
		XCTAssertTrue(s.indentSize == 4 && s.lineEnding == .lf)
	}

	func testExistingFileWins() {
		let detected = DetectedFormat(lineEnding: .crlf, indentStyle: .space, indentSize: 2)
		var r = FormatResolver.resolve(path: "/p/a.php", user: nil, project: nil, editorConfig: [:], detected: detected)
		XCTAssertTrue(r.settings.lineEnding == .crlf && r.settings.indentSize == 2 && r.indentSource == .detected)
		// .editorconfig fixes indentation: detection must not override it
		r = FormatResolver.resolve(path: "/p/a.php", user: nil, project: nil, editorConfig: ["indent_size": "4"], detected: detected)
		XCTAssertTrue(r.settings.indentSize == 4 && r.indentSource == .editorConfig)
	}

	func testEditorConfigGlobs() {
		let f = EditorConfigFile(parsing: """
		root = true
		[*]
		indent_style = space
		indent_size = 4
		[*.{js,ts}]
		indent_size = 2
		[Makefile]
		indent_style = tab
		[lib/**.php]
		indent_style = tab
		[file{1..3}.txt]
		end_of_line = crlf
		[[!a]*.md]
		charset = latin1
		""")
		XCTAssertTrue(f.root)
		XCTAssertEqual(f.properties(forRelativePath: "src/app.ts")["indent_size"], "2")
		XCTAssertEqual(f.properties(forRelativePath: "src/app.php")["indent_size"], "4")
		XCTAssertEqual(f.properties(forRelativePath: "x/Makefile")["indent_style"], "tab")
		XCTAssertEqual(f.properties(forRelativePath: "lib/deep/a.php")["indent_style"], "tab")
		XCTAssertEqual(f.properties(forRelativePath: "src/lib/a.php")["indent_style"], "space") // "/" anchors to the file's dir
		XCTAssertEqual(f.properties(forRelativePath: "file2.txt")["end_of_line"], "crlf")
		XCTAssertNil(f.properties(forRelativePath: "file4.txt")["end_of_line"])
		XCTAssertEqual(f.properties(forRelativePath: "b.md")["charset"], "latin1")
		XCTAssertNil(f.properties(forRelativePath: "a.md")["charset"])
	}

	func testEditorConfigHierarchy() {
		let files = [
			"/repo/.editorconfig": "root = true\n[*]\nindent_size = 4\nend_of_line = lf\n",
			"/repo/web/.editorconfig": "[*.php]\nindent_size = 2\n",
			"/.editorconfig": "[*]\nend_of_line = crlf\n", // above root: ignored
		]
		let p = EditorConfig.properties(forFile: "/repo/web/index.php") { files[$0] }
		XCTAssertTrue(p["indent_size"] == "2" && p["end_of_line"] == "lf")
	}

	func testLoadDetectsAndNormalizes() {
		let crlf = TextFile.load(Data("<?php\r\nclass A\r\n{\r\n  function a()\r\n  {\r\n    return 1;\r\n  }\r\n}\r\n".utf8))
		XCTAssertFalse(crlf.text.contains("\r"))
		XCTAssertTrue(crlf.detected.lineEnding == .crlf && !crlf.detected.mixedLineEndings)
		XCTAssertTrue(crlf.detected.indentStyle == .space && crlf.detected.indentSize == 2)

		let tabs = TextFile.load(Data("func a() {\n\tif x {\n\t\treturn\n\t}\n}\n".utf8))
		XCTAssertTrue(tabs.detected.indentStyle == .tab && tabs.detected.lineEnding == .lf)

		XCTAssertTrue(TextFile.load(Data("a\r\nb\nc\r\n".utf8)).detected.mixedLineEndings)

		let cp1250 = TextFile.load(Data([0x50, 0xF8, 0xED, 0x6C, 0x69, 0x9A])) // "Příliš" in windows-1250
		XCTAssertTrue(cp1250.charset == .windows1250 && cp1250.text == "Příliš")
	}

	func testSaveAppliesSettings() {
		var s = FormatSettings()
		s.lineEnding = .crlf
		let loaded = TextFile.load(Data("old  \nkeep  \n".utf8))
		let edited = loaded.text.replacingOccurrences(of: "old  ", with: "new  ")
		let out = String(decoding: TextFile.save(edited, settings: s, originalLines: loaded.originalLines), as: UTF8.self)
		// only the changed line is trimmed; CRLF everywhere; final newline kept
		XCTAssertEqual(out, "new\r\nkeep  \r\n")

		s.lineEnding = .lf
		s.trimTrailingWhitespace = .all
		s.charset = .utf8bom
		let data = TextFile.save("a  \nb", settings: s)
		XCTAssertEqual(Array(data.prefix(3)), [0xEF, 0xBB, 0xBF])
		XCTAssertEqual(String(decoding: data.dropFirst(3), as: UTF8.self), "a\nb\n")
	}

	func testWriteKeepsPermissionsAndSymlinks() throws {
		let fm = FileManager.default
		let dir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
		try fm.createDirectory(at: dir, withIntermediateDirectories: true)
		defer { try? fm.removeItem(at: dir) }

		let script = dir.appendingPathComponent("deploy.sh")
		try Data("#!/bin/sh\n".utf8).write(to: script)
		try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
		let link = dir.appendingPathComponent("link.sh")
		try fm.createSymbolicLink(at: link, withDestinationURL: script)

		try TextFile.write(Data("#!/bin/sh\necho hi\n".utf8), to: link)

		try XCTAssertEqual(fm.destinationOfSymbolicLink(atPath: link.path), script.path) // still a link
		try XCTAssertTrue(String(contentsOf: script, encoding: .utf8).contains("echo hi")) // target written
		XCTAssertEqual((try fm.attributesOfItem(atPath: script.path)[.posixPermissions] as? Int), 0o755)
	}

	func testLoadNormalizesLineEndings() {
		let mixed = TextFile.load(Data("a\r\nb\r\nc\rd\n\r".utf8))
		XCTAssertEqual(mixed.text, "a\nb\nc\nd\n\n")
		XCTAssertTrue(mixed.detected.lineEnding == .crlf && mixed.detected.mixedLineEndings)
		let lf = TextFile.load(Data("a\nb".utf8), keepLines: false)
		XCTAssertTrue(lf.text == "a\nb" && lf.detected.lineEnding == .lf && !lf.detected.mixedLineEndings && lf.originalLines.isEmpty)
	}

	func testWriteKeepsExtendedAttributes() throws {
		let fm = FileManager.default
		let dir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
		try fm.createDirectory(at: dir, withIntermediateDirectories: true)
		defer { try? fm.removeItem(at: dir) }
		let file = dir.appendingPathComponent("a.txt")
		try Data("a\n".utf8).write(to: file)
		try fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: 0)], ofItemAtPath: file.path)
		let value = Array("blue".utf8)
		XCTAssertEqual(setxattr(file.path, "cz.minoride.test", value, value.count, 0, 0), 0)

		try TextFile.write(Data("b\n".utf8), to: file)

		var buffer = [UInt8](repeating: 0, count: 16)
		let n = getxattr(file.path, "cz.minoride.test", &buffer, buffer.count, 0, 0)
		XCTAssertTrue(n == value.count && Array(buffer.prefix(max(n, 0))) == value)
		try XCTAssertEqual(String(contentsOf: file, encoding: .utf8), "b\n")
		let modified = try fm.attributesOfItem(atPath: file.path)[.modificationDate] as? Date
		XCTAssertTrue((modified ?? .distantPast) > Date(timeIntervalSince1970: 1)) // not the old date
		try XCTAssertEqual(fm.contentsOfDirectory(atPath: dir.path), ["a.txt"]) // no temp file left
	}

	func testUpdateSettingsDefaultToUnsetAndParse() throws {
		let empty = try SettingsFile(json: Data("{}".utf8))
		XCTAssertTrue(empty.autoCheckUpdates == nil && empty.autoDownloadUpdates == nil)
		let off = try SettingsFile(json: Data(#"{"auto_check_updates":false,"auto_download_updates":false}"#.utf8))
		XCTAssertTrue(off.autoCheckUpdates == false && off.autoDownloadUpdates == false)
	}
}

final class HexDumpTests: XCTestCase {
	func testRowsHaveOffsetHexAndASCII() {
		let dump = HexDump.format(Data([0x41, 0x00, 0x7F] + Array(repeating: 0x62, count: 14)))
		let lines = dump.split(separator: "\n")
		XCTAssertEqual(lines.count, 2)
		XCTAssertEqual(lines[0], "00000000  41 00 7f 62 62 62 62 62  62 62 62 62 62 62 62 62  |A..bbbbbbbbbbbbb|")
		XCTAssertTrue(lines[1].hasPrefix("00000010  62 "))
		XCTAssertTrue(lines[1].hasSuffix("|b|"))
	}
}
