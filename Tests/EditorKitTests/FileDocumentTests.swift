import AppKit
import Foundation
import Testing
import MinorCore
import TextEngine
@testable import EditorKit

/// One document per file, shared by editors in any window; edited flag, saving and disk changes.
@MainActor
struct FileDocumentTests {
	private func tempFile(_ text: String) throws -> URL {
		let dir = FileManager.default.temporaryDirectory.appendingPathComponent("FileDocumentTests-\(UUID().uuidString)")
		try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
		let url = dir.appendingPathComponent("a.go")
		try Data(text.utf8).write(to: url)
		return url
	}

	@Test func oneDocumentPerFileAcrossEditors() throws {
		let url = try tempFile("package a\n")
		let doc = try FileDocument.load(url)
		#expect(try FileDocument.load(URL(fileURLWithPath: url.deletingLastPathComponent().path + "/./a.go")) === doc)
		let a = EditorView(document: doc.text), b = EditorView(document: doc.text)
		a.setSelections(SelectionSet(caret: 0))
		a.insertText("// ", replacementRange: NSRange(location: NSNotFound, length: 0))
		#expect(b.rope.string == "// package a\n")
		#expect(doc.isEdited)

		try doc.write(to: url)
		#expect(!doc.isEdited)
		#expect(try String(contentsOf: url, encoding: .utf8) == "// package a\n")
	}

	@Test func editorConfigChangeAppliesUnlessChosenInMenu() throws {
		let url = try tempFile("{\n\n}\n") // no indented line: nothing to detect
		let config = url.deletingLastPathComponent().appendingPathComponent(".editorconfig")
		try Data("[*]\nindent_style = space\nindent_size = 2\n".utf8).write(to: config)
		let doc = try FileDocument.load(url)
		#expect(doc.format.indentSize == 2)
		try Data("[*]\nindent_style = space\nindent_size = 3\n".utf8).write(to: config)
		doc.settingsChanged()
		#expect(doc.format.indentSize == 3)
		#expect(!doc.isEdited)

		doc.formatChosenByUser = true
		try Data("[*]\nindent_style = space\nindent_size = 5\n".utf8).write(to: config)
		doc.settingsChanged()
		#expect(doc.format.indentSize == 3)
	}

	@Test func localHistoryKeepsSavedVersionsAndRestores() throws {
		let root = FileManager.default.temporaryDirectory.appendingPathComponent("FileDocumentHistory-\(UUID().uuidString)")
		FileDocument.history = LocalHistory(root: root)
		defer { FileDocument.history = nil; try? FileManager.default.removeItem(at: root) }
		let url = try tempFile("one\n")
		let doc = try FileDocument.load(url)
		let editor = EditorView(document: doc.text)
		editor.setSelections(SelectionSet(caret: 0))
		editor.insertText("two ", replacementRange: NSRange(location: NSNotFound, length: 0))
		try doc.write(to: url)
		#expect(doc.versions.count == 2) // the original from disk and the saved text

		doc.restore(doc.versions[1])
		#expect(editor.rope.string == "one\n")
		#expect(doc.isEdited)
		doc.text.history.seal()
		editor.undo(nil)
		#expect(editor.rope.string == "two one\n")
	}

	@Test func diskChangeReloadsCleanAndNotifiesEdited() throws {
		let url = try tempFile("one\n")
		let doc = try FileDocument.load(url)
		let view = EditorView(document: doc.text)
		try Data("two\n".utf8).write(to: url)
		try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: url.path)
		doc.checkDisk()
		#expect(view.rope.string == "two\n") // quiet reload
		#expect(!doc.isEdited && doc.diskNotice == nil)

		view.setSelections(SelectionSet(caret: 0))
		view.insertText("x", replacementRange: NSRange(location: NSNotFound, length: 0))
		try Data("three\n".utf8).write(to: url)
		try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(10)], ofItemAtPath: url.path)
		doc.checkDisk()
		#expect(doc.diskNotice == .changed)
		#expect(view.rope.string == "xtwo\n") // unsaved text kept until the user chooses
		doc.keepMine()
		doc.checkDisk()
		#expect(doc.diskNotice == nil)
	}

	@Test func saveAsOverOpenFileLeavesOneDocument() throws {
		let url = try tempFile("old\n")
		let open = try FileDocument.load(url)
		let other = FileDocument(text: "new\n")
		var replaced: ObjectIdentifier?
		let observer = NotificationCenter.default.addObserver(forName: FileDocument.didReplace, object: open, queue: nil) { note in
			let id = (note.userInfo?[FileDocument.replacementKey] as AnyObject?).map(ObjectIdentifier.init)
			MainActor.assumeIsolated { replaced = id }
		}
		defer { NotificationCenter.default.removeObserver(observer) }
		try other.write(to: url)
		#expect(try FileDocument.load(url) === other)
		#expect(replaced == ObjectIdentifier(other))
		#expect(open.url == nil)
	}
}
