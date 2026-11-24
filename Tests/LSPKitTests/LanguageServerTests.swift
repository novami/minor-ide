import Foundation
import XCTest
@testable import MinorIDE

final class Locked<T>: @unchecked Sendable {
	private let lock = NSLock()
	private var v: T
	init(_ v: T) { self.v = v }
	var value: T { lock.withLock { v } }
	func mutate(_ f: (inout T) -> Void) { lock.withLock { f(&v) } }
}

/// In-process language server over pipes: records notifications, answers `initialize`.
final class FakeServer: @unchecked Sendable {
	let peer: JSONRPCClient
	let client: JSONRPCClient
	let received = Locked<[(String, JSONValue)]>([])

	init(capabilities: JSONValue) {
		let toServer = Pipe(), toClient = Pipe()
		peer = JSONRPCClient(reading: toServer.fileHandleForReading, writing: toClient.fileHandleForWriting)
		client = JSONRPCClient(reading: toClient.fileHandleForReading, writing: toServer.fileHandleForWriting)
		peer.onNotification = { [received] m, p in received.mutate { $0.append((m, p)) } }
		// Like a process: when the client goes away, so does the server.
		peer.onExit = { [weak peer] in peer?.terminate() }
		peer.onRequest = { [received] m, p in
			received.mutate { $0.append((m, p)) }
			switch m {
			case "initialize": return ["capabilities": capabilities]
			case "slow":
				try await Task.sleep(for: .seconds(30))
				return .null
			default: return .null
			}
		}
	}

	func notifications(_ method: String) -> [JSONValue] { received.value.filter { $0.0 == method }.map(\.1) }

	/// Simulates a crash: the client sees the end of its input.
	func crash() { peer.terminate() }
}

final class Harness: @unchecked Sendable {
	let servers = Locked<[FakeServer]>([])
	let states = Locked<[ServerState]>([])
	let progress = Locked<[ProgressEvent]>([])
	let diagnostics = Locked<[PublishedDiagnostics]>([])
	let lsp: LanguageServer

	init(capabilities: JSONValue = ["positionEncoding": "utf-8", "textDocumentSync": 2], settings: JSONValue = [:]) {
		var h = LanguageServerHandlers()
		let states = states, progress = progress, servers = servers, diagnostics = diagnostics
		h.state = { s in states.mutate { $0.append(s) } }
		h.diagnostics = { d in diagnostics.mutate { $0.append(d) } }
		h.progress = { e in progress.mutate { $0.append(e) } }
		lsp = LanguageServer(root: URL(fileURLWithPath: "/p"), settings: settings, handlers: h) { _ in
			let s = FakeServer(capabilities: capabilities)
			servers.mutate { $0.append(s) }
			return s.client
		}
	}

	var server: FakeServer { servers.value.last! }
}

func waitUntil(_ condition: () -> Bool) async throws {
	for _ in 0..<300 where !condition() { try await Task.sleep(for: .milliseconds(10)) }
	XCTAssertTrue(condition())
}

final class LanguageServerTests: XCTestCase {
	func testSyncsDocumentsIncrementallyInNegotiatedEncoding() async throws {
		let h = Harness()
		var rope = Rope("žluť\nkůň\n")
		h.lsp.open(uri: "file:///p/a.go", languageID: "go", version: 1, text: rope)
		h.lsp.start()
		try await waitUntil { h.lsp.isRunning }
		XCTAssertEqual(h.lsp.positionEncoding, .utf8)
		try await waitUntil { h.server.notifications("textDocument/didOpen").count == 1 }
		XCTAssertEqual(h.server.notifications("initialized").count, 1)

		// Two cursors: after "ž" on line 0 and after "ků" on line 1.
		let changes = ChangeSet([(2..<2, "X"), (rope.offset(ofLine: 1) + 3..<rope.offset(ofLine: 1) + 5, "")])
		changes.apply(to: &rope)
		h.lsp.change(uri: "file:///p/a.go", version: 2, changes: changes, text: rope)
		try await waitUntil { h.server.notifications("textDocument/didChange").count == 1 }
		let change = h.server.notifications("textDocument/didChange")[0]
		XCTAssertEqual(change["textDocument"]?["version"], 2)
		let events = change["contentChanges"]?.arrayValue ?? []
		// Back to front, positions in UTF-8 bytes.
		XCTAssertEqual(events.map { LSPRange($0["range"])?.start }, [Position(line: 1, character: 3), Position(line: 0, character: 2)])
		XCTAssertEqual(events.map { $0["text"]?.stringValue }, ["", "X"])
	}

	func testAnswersServerRequestsAndForwardsWatchedFiles() async throws {
		let h = Harness(settings: ["gopls": ["staticcheck": true]])
		h.lsp.start()
		try await waitUntil { h.lsp.isRunning }
		let peer = h.server.peer
		let config = try await peer.request("workspace/configuration", ["items": [["section": "gopls"], ["section": "other"]]])
		XCTAssertEqual(config, [["staticcheck": true], .null])

		_ = try await peer.request("client/registerCapability", ["registrations": [[
			"id": "w1", "method": "workspace/didChangeWatchedFiles",
			"registerOptions": ["watchers": [["globPattern": "**/*.go"], ["globPattern": ["baseUri": "file:///p", "pattern": "go.mod"], "kind": 2]]],
		]]])
		XCTAssertTrue(h.lsp.wantsFileEvents)
		h.lsp.filesChanged([
			(URL(fileURLWithPath: "/p/x/a.go"), .created),
			(URL(fileURLWithPath: "/p/readme.md"), .changed),
			(URL(fileURLWithPath: "/p/go.mod"), .deleted), // watcher only wants changes
			(URL(fileURLWithPath: "/p/go.mod"), .changed),
		])
		try await waitUntil { h.server.notifications("workspace/didChangeWatchedFiles").count == 1 }
		let uris = h.server.notifications("workspace/didChangeWatchedFiles")[0]["changes"]?.arrayValue?.compactMap { $0["uri"]?.stringValue }
		XCTAssertEqual(uris, ["file:///p/x/a.go", "file:///p/go.mod"])

		do {
			_ = try await peer.request("unknown/method")
			XCTFail("expected an error")
		} catch let e as RPCError {
			XCTAssertEqual(e.code, -32601)
		}
	}

	func testRestartsAfterCrashAndGivesUpAfterThree() async throws {
		let h = Harness()
		h.lsp.open(uri: "file:///p/a.go", languageID: "go", version: 7, text: Rope("x"))
		h.lsp.start()
		try await waitUntil { h.lsp.isRunning }
		try h.server.peer.notify("$/progress", ["token": 1, "value": ["kind": "begin", "title": "Loading"]])
		try await waitUntil { h.progress.value.count == 1 }

		h.server.crash()
		try await waitUntil { h.servers.value.count == 2 && h.lsp.isRunning }
		// The document is reopened with its latest version; the open progress is ended.
		try await waitUntil { h.server.notifications("textDocument/didOpen").first?["textDocument"]?["version"] == 7 }
		XCTAssertEqual(h.progress.value.last, ProgressEvent(token: "1", kind: .end))

		for n in 3...4 {
			h.server.crash()
			try await waitUntil { h.servers.value.count == n && h.lsp.isRunning }
		}
		h.server.crash()
		try await waitUntil { if case .failed = h.states.value.last { true } else { false } }
		XCTAssertEqual(h.servers.value.count, 4)
	}

	func testCancellingARequestNotifiesTheServer() async throws {
		let h = Harness()
		h.lsp.start()
		try await waitUntil { h.lsp.isRunning }
		let task = Task { try await h.lsp.request("slow") }
		try await waitUntil { h.server.received.value.contains { $0.0 == "slow" } }
		task.cancel()
		do { _ = try await task.value; XCTFail("expected an error") } catch {}
		try await waitUntil { h.server.notifications("$/cancelRequest").count == 1 }
	}

	func testStopShutsDownWithoutRestart() async throws {
		let h = Harness()
		h.lsp.start()
		try await waitUntil { h.lsp.isRunning }
		await h.lsp.stop()
		try await waitUntil { h.states.value.last == .stopped }
		XCTAssertTrue(h.server.received.value.contains { $0.0 == "shutdown" })
		XCTAssertEqual(h.server.notifications("exit").count, 1)
		XCTAssertEqual(h.servers.value.count, 1)
	}
}
