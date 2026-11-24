import Foundation
import XCTest
@testable import MinorIDE

final class GoplsTests: XCTestCase {
	func testLanguageIDs() {
		XCTAssertEqual(Gopls.languageID(forPath: "/p/main.go"), "go")
		XCTAssertEqual(Gopls.languageID(forPath: "/p/go.mod"), "go.mod")
		XCTAssertEqual(Gopls.languageID(forPath: "/p/go.work"), "go.work")
		XCTAssertNil(Gopls.languageID(forPath: "/p/main.go.txt"))
		XCTAssertNil(Gopls.languageID(forPath: "/p/index.php"))
	}

	func testLocatesInPathThenGoBinFolders() {
		let env = ["GOPATH": "/gp:/other", "GOBIN": "/gobin"]
		XCTAssertEqual(Gopls.locate(which: { _ in "/usr/local/bin/gopls" }, environment: env, home: "/h"), "/usr/local/bin/gopls")
		XCTAssertEqual(Gopls.locate(which: { _ in nil }, environment: env, home: "/h", isExecutable: { $0 == "/gp/bin/gopls" }), "/gp/bin/gopls")
		XCTAssertEqual(Gopls.locate(which: { _ in nil }, environment: env, home: "/h", isExecutable: { $0 == "/gobin/gopls" }), "/gobin/gopls")
		XCTAssertEqual(Gopls.locate(which: { _ in nil }, environment: [:], home: "/h", isExecutable: { $0 == "/h/go/bin/gopls" }), "/h/go/bin/gopls")
		XCTAssertNil(Gopls.locate(which: { _ in nil }, environment: [:], home: "/h", isExecutable: { _ in false }))
	}

	func testProgressShowsNewestRunningTask() {
		var p = ProgressTracker()
		p.apply(ProgressEvent(token: "a", kind: .begin, title: "Loading packages"))
		p.apply(ProgressEvent(token: "a", kind: .report, message: "3/10", percentage: 30))
		XCTAssertEqual(p.text, "Loading packages: 3/10 30 %")
		p.apply(ProgressEvent(token: "b", kind: .begin, title: "Indexing"))
		XCTAssertEqual(p.text, "Indexing")
		p.apply(ProgressEvent(token: "b", kind: .end))
		XCTAssertEqual(p.text, "Loading packages: 3/10 30 %")
		p.apply(ProgressEvent(token: "x", kind: .report, message: "unknown"))
		p.apply(ProgressEvent(token: "a", kind: .end))
		XCTAssertTrue(p.text == nil && !p.isActive)
	}

	/// Against the real server when it is installed: open, incremental change, request.
	func testRealGoplsSeesIncrementalChanges() async throws {
		try XCTSkipIf(realGopls == nil, "gopls is not installed")
		let gopls = try XCTUnwrap(realGopls)
		let dir = FileManager.default.temporaryDirectory.appendingPathComponent("gopls-\(UUID().uuidString)")
		try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: dir) }
		try "module example.com/t\n\ngo 1.22\n".write(to: dir.appendingPathComponent("go.mod"), atomically: true, encoding: .utf8)
		let source = "package main\n\n// Čau 👋\nfunc main() {}\n"
		let file = dir.appendingPathComponent("main.go")
		try source.write(to: file, atomically: true, encoding: .utf8)

		var env = ProcessInfo.processInfo.environment
		env["PATH"] = (gopls as NSString).deletingLastPathComponent + ":" + (env["PATH"] ?? "/usr/bin:/bin")
		let states = Locked<[ServerState]>([])
		var handlers = LanguageServerHandlers()
		handlers.state = { s in states.mutate { $0.append(s) } }
		let server = LanguageServer(command: ServerCommand(executable: URL(fileURLWithPath: gopls), environment: env, directory: dir),
		                            root: dir, initializationOptions: Gopls.initializationOptions, settings: Gopls.settings, handlers: handlers)
		server.start()
		var text = Rope(source)
		let uri = file.absoluteString
		server.open(uri: uri, languageID: "go", version: 1, text: text)
		// After the emoji, so a wrong position encoding would garble the inserted function.
		let at = text.byteCount
		let changes = ChangeSet([(at..<at, "\nfunc helper() int { return 1 }\n")])
		changes.apply(to: &text)
		server.change(uri: uri, version: 2, changes: changes, text: text)

		var names: [String] = []
		for _ in 0..<100 {
			let result = try? await server.request("textDocument/documentSymbol", ["textDocument": ["uri": .string(uri)]])
			names = (result?.arrayValue ?? []).compactMap { $0["name"]?.stringValue }
			if names.contains("helper") { break }
			try await Task.sleep(for: .milliseconds(200))
		}
		XCTAssertEqual(names, ["main", "helper"])
		XCTAssertTrue(states.value.contains(.running))

		let hover = try await server.hover(uri: uri, offset: text.string.components(separatedBy: "func helper")[0].utf8.count + 7, in: text)
		XCTAssertEqual(hover?.contents.blocks.first, .code("func helper() int", language: "go"))
		// Inside a call, after the comma: the second parameter (inside the string literal gopls has none).
		let call = "func use(a int, b string) {}\nfunc z() { use(1, \"x\") }\n"
		let tail = text.byteCount
		let more = ChangeSet([(tail..<tail, call)])
		more.apply(to: &text)
		server.change(uri: uri, version: 3, changes: more, text: text)
		let caret = text.byteCount - " \"x\") }\n".utf8.count
		let help = try await server.signatureHelp(uri: uri, offset: caret, in: text, trigger: .character(0x2C), current: nil)
		XCTAssertEqual(help?.active.label, "use(a int, b string)")
		XCTAssertEqual(help?.activeParameter, 1)
		XCTAssertEqual(help.map { (help!.active.label as NSString).substring(with: NSRange(location: $0.active.parameters[1].range.lowerBound, length: $0.active.parameters[1].range.count)) }, "b string")

		// Formatting: only the selected line changes, then the whole file.
		// After a blank line, so gofmt does not align these with the functions above.
		let messy = "\nfunc a()  {}\nfunc b()  {}\n"
		let end = text.byteCount, start = end + 1
		let add = ChangeSet([(end..<end, messy)])
		add.apply(to: &text)
		server.change(uri: uri, version: 4, changes: add, text: text)
		XCTAssertTrue(server.supportsFormatting)
		let formatted = try await server.format(uri: uri, range: start..<(start + 3), in: text, settings: FormatSettings())
		let first = try XCTUnwrap(formatted)
		var partly = text
		ChangeSet(first).apply(to: &partly)
		XCTAssertTrue(partly.string.hasSuffix("func a() {}\nfunc b()  {}\n"))
		let formattedAll = try await server.format(uri: uri, in: text, settings: FormatSettings())
		let all = try XCTUnwrap(formattedAll)
		ChangeSet(all).apply(to: &text)
		XCTAssertTrue(text.string.hasSuffix("func a() {}\nfunc b() {}\n"))
		server.change(uri: uri, version: 5, changes: ChangeSet(all), text: text)

		// Crash: the server restarts and gets the unsaved text again.
		let pid = try XCTUnwrap(server.processIdentifier)
		kill(pid, SIGKILL)
		var restarted: [String] = []
		for _ in 0..<100 {
			try await Task.sleep(for: .milliseconds(200))
			guard server.isRunning, server.processIdentifier != pid else { continue }
			let result = try? await server.request("textDocument/documentSymbol", ["textDocument": ["uri": .string(uri)]])
			restarted = (result?.arrayValue ?? []).compactMap { $0["name"]?.stringValue }
			if restarted.contains("b") { break }
		}
		XCTAssertEqual(restarted, ["main", "helper", "use", "z", "a", "b"])
		XCTAssertTrue(states.value.contains(.restarting(attempt: 1)))
		await server.stop()
	}
}

private let realGopls: String? = ["/opt/homebrew/bin/gopls", "/usr/local/bin/gopls", NSHomeDirectory() + "/go/bin/gopls"]
	.first { FileManager.default.isExecutableFile(atPath: $0) }
