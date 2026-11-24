import Foundation
import XCTest
@testable import MinorIDE

final class DiagnosticsTests: XCTestCase {
	func testParsesDiagnostics() {
		let report = PublishedDiagnostics([
			"uri": "file:///p/a.go", "version": 3,
			"diagnostics": [
				["range": ["start": ["line": 1, "character": 0], "end": ["line": 1, "character": 2]], "message": "undefined: x",
				 "severity": 1, "source": "compiler", "code": "UndeclaredName",
				 "codeDescription": ["href": "https://pkg.go.dev/x"],
				 "relatedInformation": [["location": ["uri": "file:///p/b.go", "range": ["start": ["line": 4, "character": 1], "end": ["line": 4, "character": 2]]],
				                         "message": "other declaration"]]],
				["range": ["start": ["line": 0, "character": 0], "end": ["line": 0, "character": 1]], "message": "unused", "severity": 4,
				 "code": 1001, "tags": [1]],
				["message": "no range"],
			],
		])
		XCTAssertEqual(report?.version, 3)
		XCTAssertEqual(report?.diagnostics.map(\.severity), [.error, .hint])
		XCTAssertEqual(report?.diagnostics.map(\.code), ["UndeclaredName", "1001"])
		XCTAssertEqual(report?.diagnostics.last?.unnecessary, true)
		XCTAssertEqual(report?.diagnostics.first?.href, "https://pkg.go.dev/x")
		XCTAssertEqual(report?.diagnostics.first?.related.map(\.message), ["other declaration"])
		XCTAssertEqual(report?.diagnostics.first?.related.first?.location.range.start, Position(line: 4, character: 1))
	}

	/// Ranges are bytes in the text of the version the server diagnosed, also after later edits.
	func testRangesAreInTheDiagnosedVersion() async throws {
		let h = Harness()
		var rope = Rope("ab\nčd\n")
		h.lsp.open(uri: "file:///p/a.go", languageID: "go", version: 1, text: rope)
		h.lsp.start()
		try await waitUntil { h.lsp.isRunning }
		try await waitUntil { h.server.notifications("textDocument/didOpen").count == 1 }
		let changes = ChangeSet([(0..<0, "XX")])
		changes.apply(to: &rope)
		h.lsp.change(uri: "file:///p/a.go", version: 2, changes: changes, text: rope)
		try await waitUntil { h.server.notifications("textDocument/didChange").count == 1 }

		let d: JSONValue = ["range": ["start": ["line": 1, "character": 0], "end": ["line": 1, "character": 2]], "message": "m"]
		try h.server.peer.notify("textDocument/publishDiagnostics", ["uri": "file:///p/a.go", "version": 1, "diagnostics": [d]])
		try h.server.peer.notify("textDocument/publishDiagnostics", ["uri": "file:///p/a.go", "version": 2, "diagnostics": [d]])
		try h.server.peer.notify("textDocument/publishDiagnostics", ["uri": "file:///p/b.go", "diagnostics": [d]])
		try await waitUntil { h.diagnostics.value.count == 3 }
		let got = h.diagnostics.value
		XCTAssertTrue(got[0].version == 1 && got[0].ranges == [3..<5]) // "č" before the edit
		XCTAssertTrue(got[1].version == 2 && got[1].ranges == [5..<7])
		XCTAssertEqual(got[2].ranges, nil) // not open
	}
}
