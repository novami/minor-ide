import AppKit
import Testing
import TextEngine
@testable import EditorKit

@MainActor
struct GitGutterTests {
	private func waitForChanges(_ doc: TextDocument, count: Int) async {
		for _ in 0..<200 where doc.gitChanges.count != count { try? await Task.sleep(for: .milliseconds(10)) }
	}

	@Test func changesFollowEditsAndRevertRestoresCommittedLines() async {
		let committed = "a\nb\nc\nd"
		let doc = TextDocument(text: committed)
		let editor = EditorView(document: doc)
		doc.gitBase = LineChanges.lines(committed)
		await waitForChanges(doc, count: 0)
		#expect(doc.gitChanges.isEmpty)

		editor.replace(doc.rope.offset(ofLine: 1)..<doc.rope.offset(ofLine: 2), with: "B\nB2\n") // modified
		editor.replace((doc.rope.offset(ofLine: 4) - 1)..<doc.rope.byteCount, with: "") // last line deleted
		await waitForChanges(doc, count: 2)
		#expect(doc.gitChanges.map(\.kind) == [.modified, .deleted])
		for change in doc.gitChanges.reversed() { editor.revert(change) }
		#expect(doc.rope.string == committed)

		editor.replace(doc.rope.byteCount..<doc.rope.byteCount, with: "\ne") // added at the end
		await waitForChanges(doc, count: 1)
		#expect(doc.gitChanges.first?.kind == .added)
		editor.revert(doc.gitChanges[0])
		#expect(doc.rope.string == committed)
	}
}
