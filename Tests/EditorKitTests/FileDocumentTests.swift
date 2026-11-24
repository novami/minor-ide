import AppKit
import Foundation
import XCTest
@testable import MinorIDE

/// One document per file, shared by editors in any window; edited flag, saving and disk changes.
@MainActor
final class FileDocumentTests: XCTestCase {
	private func tempFile(_ text: String) throws -> URL {
		let dir = FileManager.default.temporaryDirectory.appendingPathComponent("FileDocumentTests-\(UUID().uuidString)")
		try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
		let url = dir.appendingPathComponent("a.go")
		try Data(text.utf8).write(to: url)
		return url
	}

	func testOneDocumentPerFileAcrossEditors() throws {
		let url = try tempFile("package a\n")
		let doc = try FileDocument.load(url)
		XCTAssertTrue(try FileDocument.load(URL(fileURLWithPath: url.deletingLastPathComponent().path + "/./a.go")) === doc)
		let a = EditorView(document: doc.text), b = EditorView(document: doc.text)
		a.setSelections(SelectionSet(caret: 0))
		a.insertText("// ", replacementRange: NSRange(location: NSNotFound, length: 0))
		XCTAssertEqual(b.rope.string, "// package a\n")
		XCTAssertTrue(doc.isEdited)

		try doc.write(to: url)
		XCTAssertFalse(doc.isEdited)
		try XCTAssertEqual(String(contentsOf: url, encoding: .utf8), "// package a\n")
	}

	func testReplaceInFilesEditsOpenFilesAndWritesOthers() throws {
		let url = try tempFile("a := 1\r\nb := a\r\n")
		let query = FindQuery(text: "a", wholeWord: true)
		// Not open: written at once, line endings kept.
		try XCTAssertEqual(FileDocument.replace(in: url) { try $0.replacements(of: query, with: "x", preserveCase: false) }, 2)
		try XCTAssertEqual(String(contentsOf: url, encoding: .utf8), "x := 1\r\nb := x\r\n")
		// Open: changed in the editor, one undo step, not saved.
		let doc = try FileDocument.load(url)
		let editor = EditorView(document: doc.text)
		try XCTAssertEqual(FileDocument.replace(in: url) { try $0.replacements(of: FindQuery(text: "x"), with: "y", preserveCase: false) }, 2)
		XCTAssertTrue(doc.isEdited && editor.rope.string.hasPrefix("y := 1"))
		try XCTAssertTrue(String(contentsOf: url, encoding: .utf8).hasPrefix("x := 1"))
		editor.undo(nil)
		XCTAssertTrue(editor.rope.string.hasPrefix("x := 1"))
	}

	func testEditorConfigChangeAppliesUnlessChosenInMenu() throws {
		let url = try tempFile("{\n\n}\n") // no indented line: nothing to detect
		let config = url.deletingLastPathComponent().appendingPathComponent(".editorconfig")
		try Data("[*]\nindent_style = space\nindent_size = 2\n".utf8).write(to: config)
		let doc = try FileDocument.load(url)
		XCTAssertEqual(doc.format.indentSize, 2)
		try Data("[*]\nindent_style = space\nindent_size = 3\n".utf8).write(to: config)
		doc.settingsChanged()
		XCTAssertEqual(doc.format.indentSize, 3)
		XCTAssertFalse(doc.isEdited)

		doc.formatChosenByUser = true
		try Data("[*]\nindent_style = space\nindent_size = 5\n".utf8).write(to: config)
		doc.settingsChanged()
		XCTAssertEqual(doc.format.indentSize, 3)
	}

	func testLocalHistoryKeepsSavedVersionsAndRestores() throws {
		let root = FileManager.default.temporaryDirectory.appendingPathComponent("FileDocumentHistory-\(UUID().uuidString)")
		FileDocument.history = LocalHistory(root: root)
		defer { FileDocument.history = nil; try? FileManager.default.removeItem(at: root) }
		let url = try tempFile("one\n")
		let doc = try FileDocument.load(url)
		let editor = EditorView(document: doc.text)
		editor.setSelections(SelectionSet(caret: 0))
		editor.insertText("two ", replacementRange: NSRange(location: NSNotFound, length: 0))
		try doc.write(to: url)
		XCTAssertEqual(doc.versions.count, 2) // the original from disk and the saved text

		doc.restore(doc.versions[1])
		XCTAssertEqual(editor.rope.string, "one\n")
		XCTAssertTrue(doc.isEdited)
		doc.text.history.seal()
		editor.undo(nil)
		XCTAssertEqual(editor.rope.string, "two one\n")
	}

	func testBackupsLiveUntilSavedAndRecoverMarksEdited() throws {
		let root = FileManager.default.temporaryDirectory.appendingPathComponent("FileDocumentBackups-\(UUID().uuidString)")
		let store = BackupStore(root: root)
		FileDocument.backups = store
		defer { FileDocument.backups = nil; try? FileManager.default.removeItem(at: root) }
		let url = try tempFile("one\n")
		let doc = try FileDocument.load(url)
		let editor = EditorView(document: doc.text)
		editor.setSelections(SelectionSet(caret: 0))
		editor.insertText("x", replacementRange: NSRange(location: NSNotFound, length: 0))
		doc.backUpNow()
		FileDocument.flushBackups()
		XCTAssertEqual(store.all().map(\.text), ["xone\n"])
		XCTAssertEqual(store.all().first?.path, url.standardizedFileURL.path)
		try doc.write(to: url)
		FileDocument.flushBackups()
		XCTAssertTrue(store.all().isEmpty)

		let untitled = FileDocument(text: "")
		_ = EditorView(document: untitled.text)
		untitled.recover("lost text")
		FileDocument.flushBackups()
		XCTAssertTrue(untitled.isEdited)
		XCTAssertEqual(store.all().map(\.text), ["lost text"])
		untitled.discardChanges()
		FileDocument.flushBackups()
		XCTAssertTrue(store.all().isEmpty)
	}

	func testAutoSaveSkipsUntitledAndFilesChangedOnDisk() throws {
		XCTAssertFalse(FileDocument(text: "x").autoSave())
		let url = try tempFile("one\n")
		let doc = try FileDocument.load(url)
		let editor = EditorView(document: doc.text)
		editor.setSelections(SelectionSet(caret: 0))
		editor.insertText("a", replacementRange: NSRange(location: NSNotFound, length: 0))
		try Data("theirs\n".utf8).write(to: url)
		try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: url.path)
		doc.checkDisk()
		XCTAssertFalse(doc.autoSave())
		try XCTAssertEqual(String(contentsOf: url, encoding: .utf8), "theirs\n")
		doc.keepMine()
		XCTAssertTrue(doc.autoSave())
		try XCTAssertEqual(String(contentsOf: url, encoding: .utf8), "aone\n")
		XCTAssertFalse(doc.isEdited)
	}

	func testDiskChangeReloadsCleanAndNotifiesEdited() throws {
		let url = try tempFile("one\n")
		let doc = try FileDocument.load(url)
		let view = EditorView(document: doc.text)
		try Data("two\n".utf8).write(to: url)
		try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: url.path)
		doc.checkDisk()
		XCTAssertEqual(view.rope.string, "two\n") // quiet reload
		XCTAssertTrue(!doc.isEdited && doc.diskNotice == nil)

		view.setSelections(SelectionSet(caret: 0))
		view.insertText("x", replacementRange: NSRange(location: NSNotFound, length: 0))
		try Data("three\n".utf8).write(to: url)
		try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(10)], ofItemAtPath: url.path)
		doc.checkDisk()
		XCTAssertEqual(doc.diskNotice, .changed)
		XCTAssertEqual(view.rope.string, "xtwo\n") // unsaved text kept until the user chooses
		doc.keepMine()
		doc.checkDisk()
		XCTAssertNil(doc.diskNotice)
	}

	func testSaveAsOverOpenFileLeavesOneDocument() throws {
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
		XCTAssertTrue(try FileDocument.load(url) === other)
		XCTAssertEqual(replaced, ObjectIdentifier(other))
		XCTAssertNil(open.url)
	}
}
