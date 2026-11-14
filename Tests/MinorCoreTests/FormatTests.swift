import Foundation
import Testing
@testable import MinorCore

struct FormatTests {
	func resolve(_ path: String, user: SettingsFile? = nil, project: SettingsFile? = nil,
	             editorConfig: [String: String] = [:], detected: DetectedFormat? = nil) -> FormatSettings {
		FormatResolver.resolve(path: path, user: user, project: project, editorConfig: editorConfig, detected: detected).settings
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
}
