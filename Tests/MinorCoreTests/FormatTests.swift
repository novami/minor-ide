import Foundation
import Testing
@testable import MinorCore

struct FormatTests {
	func resolve(_ path: String, user: SettingsFile? = nil, project: SettingsFile? = nil,
	             editorConfig: [String: String] = [:], detected: DetectedFormat? = nil) -> FormatSettings {
		FormatResolver.resolve(path: path, user: user, project: project, editorConfig: editorConfig, detected: detected).settings
	}

	@Test func settingsUpdateKeepsOtherKeys() throws {
		let start = Data(#"{"detect_indent": true, "other": [1], "format": {"go": {"tab_width": 8}}}"#.utf8)
		var data = try SettingsFile.updating(start, section: "php", key: "preset", value: .string("nette"))
		data = try SettingsFile.updating(data, section: "go", key: "tab_width", value: nil)
		data = try SettingsFile.updating(data, section: nil, key: "detect_indent", value: .bool(false))
		let file = try SettingsFile(json: data)
		#expect(file.format == ["php": ["preset": "nette"]])
		#expect(file.detectIndent == false)
		#expect(String(decoding: data, as: UTF8.self).contains(#""other" : ["#))
		#expect(String(decoding: try SettingsFile.updating(nil, section: "*", key: "tab_width", value: .number(4)), as: UTF8.self).contains(#""tab_width" : 4"#))
		#expect(throws: SettingsFile.UpdateError.self) { try SettingsFile.updating(Data("{oops".utf8), section: nil, key: "a", value: nil) }
	}

	@Test func findsCharactersTheCharsetCannotStore() {
		#expect(TextFile.firstUnencodable("Příliš žluťoučký", charset: .windows1250) == nil)
		#expect(TextFile.firstUnencodable("cena 5 € a → šipka", charset: .iso88592) == "€")
		#expect(TextFile.firstUnencodable("emoji 🙂", charset: .utf8) == nil)
	}

	@Test func binaryFilesHaveNulBytes() {
		#expect(TextFile.looksBinary(Data([0x89, 0x50, 0x4E, 0x47, 0x00, 0x01])))
		#expect(!TextFile.looksBinary(Data("<?php echo 1;".utf8)))
		#expect(!TextFile.looksBinary(Data([0xFF, 0xFE, 0x61, 0x00])))
	}

	@Test func simplifiedModeForLargeOrMinifiedFiles() {
		#expect(!TextFile.needsSimplifiedMode(Data("a\nb".utf8)))
		#expect(TextFile.needsSimplifiedMode(Data(("x\n" + String(repeating: "y", count: 11)).utf8), maxLine: 10))
		#expect(TextFile.needsSimplifiedMode(Data(String(repeating: "z", count: 20).utf8), maxBytes: 10))
	}

	@Test func standardDefaults() {
		let php = resolve("/p/src/User.php")
		#expect(php.indentStyle == .space && php.indentSize == 4 && php.lineEnding == .lf)
		#expect(php.insertFinalNewline && php.charset == .utf8 && php.maxLineLength == 120)
		#expect(resolve("/p/main.go").indentStyle == .tab)
		#expect(resolve("/p/app/UI/default.latte").indentStyle == .tab)
		#expect(resolve("/p/config/common.neon").indentStyle == .tab)
		#expect(resolve("/p/a.yaml").indentSize == 2)
		#expect(resolve("/p/package.json").indentSize == 2)
		#expect(resolve("/p/composer.json").indentSize == 4)
		#expect(resolve("/p/Makefile").indentStyle == .tab)
		#expect(resolve("/p/run.bat").lineEnding == .crlf)
		#expect(resolve("/p/README.md").trimTrailingWhitespace == .none)
	}

	@Test func precedence() throws {
		let user = try SettingsFile(json: Data(#"{"format": {"*": {"end_of_line": "crlf"}, "php": {"preset": "nette"}}}"#.utf8))
		var s = resolve("/p/a.php", user: user)
		#expect(s.indentStyle == .tab && s.lineEnding == .crlf)

		let project = try SettingsFile(json: Data(#"{"format": {"php": {"indent_style": "space", "indent_size": 2}}}"#.utf8))
		s = resolve("/p/a.php", user: user, project: project)
		#expect(s.indentStyle == .space && s.indentSize == 2)

		s = resolve("/p/a.php", user: user, project: project, editorConfig: ["indent_size": "4", "end_of_line": "lf"])
		#expect(s.indentSize == 4 && s.lineEnding == .lf)
	}

	@Test func existingFileWins() {
		let detected = DetectedFormat(lineEnding: .crlf, indentStyle: .space, indentSize: 2)
		var r = FormatResolver.resolve(path: "/p/a.php", user: nil, project: nil, editorConfig: [:], detected: detected)
		#expect(r.settings.lineEnding == .crlf && r.settings.indentSize == 2 && r.indentSource == .detected)
		// .editorconfig fixes indentation: detection must not override it
		r = FormatResolver.resolve(path: "/p/a.php", user: nil, project: nil, editorConfig: ["indent_size": "4"], detected: detected)
		#expect(r.settings.indentSize == 4 && r.indentSource == .editorConfig)
	}

	@Test func editorConfigGlobs() {
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
		#expect(f.root)
		#expect(f.properties(forRelativePath: "src/app.ts")["indent_size"] == "2")
		#expect(f.properties(forRelativePath: "src/app.php")["indent_size"] == "4")
		#expect(f.properties(forRelativePath: "x/Makefile")["indent_style"] == "tab")
		#expect(f.properties(forRelativePath: "lib/deep/a.php")["indent_style"] == "tab")
		#expect(f.properties(forRelativePath: "src/lib/a.php")["indent_style"] == "space") // "/" anchors to the file's dir
		#expect(f.properties(forRelativePath: "file2.txt")["end_of_line"] == "crlf")
		#expect(f.properties(forRelativePath: "file4.txt")["end_of_line"] == nil)
		#expect(f.properties(forRelativePath: "b.md")["charset"] == "latin1")
		#expect(f.properties(forRelativePath: "a.md")["charset"] == nil)
	}

	@Test func editorConfigHierarchy() {
		let files = [
			"/repo/.editorconfig": "root = true\n[*]\nindent_size = 4\nend_of_line = lf\n",
			"/repo/web/.editorconfig": "[*.php]\nindent_size = 2\n",
			"/.editorconfig": "[*]\nend_of_line = crlf\n", // above root: ignored
		]
		let p = EditorConfig.properties(forFile: "/repo/web/index.php") { files[$0] }
		#expect(p["indent_size"] == "2" && p["end_of_line"] == "lf")
	}

	@Test func loadDetectsAndNormalizes() {
		let crlf = TextFile.load(Data("<?php\r\nclass A\r\n{\r\n  function a()\r\n  {\r\n    return 1;\r\n  }\r\n}\r\n".utf8))
		#expect(!crlf.text.contains("\r"))
		#expect(crlf.detected.lineEnding == .crlf && !crlf.detected.mixedLineEndings)
		#expect(crlf.detected.indentStyle == .space && crlf.detected.indentSize == 2)

		let tabs = TextFile.load(Data("func a() {\n\tif x {\n\t\treturn\n\t}\n}\n".utf8))
		#expect(tabs.detected.indentStyle == .tab && tabs.detected.lineEnding == .lf)

		#expect(TextFile.load(Data("a\r\nb\nc\r\n".utf8)).detected.mixedLineEndings)

		let cp1250 = TextFile.load(Data([0x50, 0xF8, 0xED, 0x6C, 0x69, 0x9A])) // "Příliš" in windows-1250
		#expect(cp1250.charset == .windows1250 && cp1250.text == "Příliš")
	}

	@Test func saveAppliesSettings() {
		var s = FormatSettings()
		s.lineEnding = .crlf
		let loaded = TextFile.load(Data("old  \nkeep  \n".utf8))
		let edited = loaded.text.replacingOccurrences(of: "old  ", with: "new  ")
		let out = String(decoding: TextFile.save(edited, settings: s, originalLines: loaded.originalLines), as: UTF8.self)
		// only the changed line is trimmed; CRLF everywhere; final newline kept
		#expect(out == "new\r\nkeep  \r\n")

		s.lineEnding = .lf
		s.trimTrailingWhitespace = .all
		s.charset = .utf8bom
		let data = TextFile.save("a  \nb", settings: s)
		#expect(Array(data.prefix(3)) == [0xEF, 0xBB, 0xBF])
		#expect(String(decoding: data.dropFirst(3), as: UTF8.self) == "a\nb\n")
	}

	@Test func writeKeepsPermissionsAndSymlinks() throws {
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

		#expect(try fm.destinationOfSymbolicLink(atPath: link.path) == script.path) // still a link
		#expect(try String(contentsOf: script, encoding: .utf8).contains("echo hi")) // target written
		#expect((try fm.attributesOfItem(atPath: script.path)[.posixPermissions] as? Int) == 0o755)
	}

	@Test func loadNormalizesLineEndings() {
		let mixed = TextFile.load(Data("a\r\nb\r\nc\rd\n\r".utf8))
		#expect(mixed.text == "a\nb\nc\nd\n\n")
		#expect(mixed.detected.lineEnding == .crlf && mixed.detected.mixedLineEndings)
		let lf = TextFile.load(Data("a\nb".utf8), keepLines: false)
		#expect(lf.text == "a\nb" && lf.detected.lineEnding == .lf && !lf.detected.mixedLineEndings && lf.originalLines.isEmpty)
	}

	@Test func writeKeepsExtendedAttributes() throws {
		let fm = FileManager.default
		let dir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
		try fm.createDirectory(at: dir, withIntermediateDirectories: true)
		defer { try? fm.removeItem(at: dir) }
		let file = dir.appendingPathComponent("a.txt")
		try Data("a\n".utf8).write(to: file)
		try fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: 0)], ofItemAtPath: file.path)
		let value = Array("blue".utf8)
		#expect(setxattr(file.path, "cz.minoride.test", value, value.count, 0, 0) == 0)

		try TextFile.write(Data("b\n".utf8), to: file)

		var buffer = [UInt8](repeating: 0, count: 16)
		let n = getxattr(file.path, "cz.minoride.test", &buffer, buffer.count, 0, 0)
		#expect(n == value.count && Array(buffer.prefix(max(n, 0))) == value)
		#expect(try String(contentsOf: file, encoding: .utf8) == "b\n")
		let modified = try fm.attributesOfItem(atPath: file.path)[.modificationDate] as? Date
		#expect((modified ?? .distantPast) > Date(timeIntervalSince1970: 1)) // not the old date
		#expect(try fm.contentsOfDirectory(atPath: dir.path) == ["a.txt"]) // no temp file left
	}
}

struct HexDumpTests {
	@Test func rowsHaveOffsetHexAndASCII() {
		let dump = HexDump.format(Data([0x41, 0x00, 0x7F] + Array(repeating: 0x62, count: 14)))
		let lines = dump.split(separator: "\n")
		#expect(lines.count == 2)
		#expect(lines[0] == "00000000  41 00 7f 62 62 62 62 62  62 62 62 62 62 62 62 62  |A..bbbbbbbbbbbbb|")
		#expect(lines[1].hasPrefix("00000010  62 "))
		#expect(lines[1].hasSuffix("|b|"))
	}
}
