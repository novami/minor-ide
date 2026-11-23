import AppKit
import Localization
import EditorKit
import LSPKit
import MinorCore
import TextEngine

/// Applies a `WorkspaceEdit`: open files change in their editors (one undo step each),
/// others are written at once like Replace in Files (previous versions in Local History).
@MainActor
enum WorkspaceEditor {
	/// Nil when applied, else what went wrong.
	static func apply(_ edit: WorkspaceEdit, encoding: PositionEncoding) -> String? {
		if edit.hasFileOperations { return Strings.codeActions.fileOperationsUnsupported }
		// All or nothing: a file edited since the server computed the change stops it.
		for f in edit.files {
			guard let url = f.url else { return Strings.codeActions.remoteFileUnsupported }
			if let version = f.version, let doc = FileDocument.document(for: url), doc.text.version != version {
				return Strings.codeActions.fileChangedNamed(name: url.lastPathComponent)
			}
		}
		var failed: [String] = []
		for f in edit.files {
			guard let url = f.url else { continue }
			do {
				try FileDocument.replace(in: url) { rope in
					guard let list = rope.replacements(f.edits, encoding: encoding) else { throw CocoaError(.fileWriteUnknown) }
					return list
				}
			} catch {
				failed.append(url.lastPathComponent)
			}
		}
		return failed.isEmpty ? nil : Strings.refactor.someFilesFailed + "\n" + failed.prefix(10).joined(separator: "\n")
	}

	static func report(_ message: String, in window: NSWindow?) {
		let alert = NSAlert()
		alert.messageText = message
		if let window { alert.beginSheetModal(for: window) } else { alert.runModal() }
	}
}

/// Quick Actions (⌥↩): fixes for the problems at the caret and refactorings of the selection
/// as a menu at the caret; Rename… (⇧F6) in a sheet with a preview of every change (plan 3.7).
@MainActor
final class CodeActionController {
	private weak var editor: EditorView?
	private let endpoint: () -> (server: LanguageServer, uri: String)?
	private var generation = 0
	private(set) var renameSheet: RenameSheet?

	init(editor: EditorView, endpoint: @escaping () -> (server: LanguageServer, uri: String)?) {
		self.editor = editor
		self.endpoint = endpoint
	}

	var canShowActions: Bool { endpoint()?.server.supportsCodeActions ?? false }
	var canRename: Bool { endpoint()?.server.supportsRename ?? false }

	// MARK: Quick actions

	func showActions() {
		guard endpoint()?.server.supportsCodeActions == true else { return NSSound.beep() }
		generation += 1
		let gen = generation
		Task { [weak self] in
			guard let found = await self?.actionsAtCaret(), let self, gen == generation else { return }
			showMenu(found.actions, at: found.offset, version: found.version)
		}
	}

	/// The actions for the selection and the problems it touches; nil when the text changed meanwhile.
	func actionsAtCaret() async -> (actions: [CodeAction], offset: Int, version: Int)? {
		guard let editor, let end = endpoint(), end.server.supportsCodeActions else { return nil }
		let rope = editor.rope, version = editor.document.version, encoding = end.server.positionEncoding
		let selection = editor.selections.primary.range
		// The problems at the caret or in the selection, with their ranges in the current text.
		let diagnostics: [JSONValue] = editor.document.diagnostics.compactMap { d in
			let touches = d.range.overlaps(selection) || d.range.contains(selection.lowerBound)
				|| d.range.upperBound == selection.lowerBound || (d.range.isEmpty && selection.contains(d.range.lowerBound))
			guard touches, case .object(var json) = d.data else { return nil }
			json["range"] = rope.lspRange(d.range, encoding: encoding).json
			return .object(json)
		}
		let actions: [CodeAction]
		do {
			actions = try await end.server.codeActions(uri: end.uri, range: selection, in: rope, diagnostics: diagnostics)
		} catch is CancellationError {
			return nil
		} catch {
			actions = []
		}
		guard self.editor?.document.version == version else { return nil }
		return (actions, selection.lowerBound, version)
	}

	private func showMenu(_ actions: [CodeAction], at offset: Int, version: Int) {
		guard let editor, let window = editor.window else { return }
		let menu = NSMenu()
		menu.autoenablesItems = false
		// Fixes first (the preferred one on top), then refactorings, then actions on the whole file.
		func rank(_ a: CodeAction) -> Int {
			if a.isQuickFix { return a.isPreferred ? 0 : 1 }
			return a.kind.hasPrefix("source") ? 3 : 2
		}
		let sorted = actions.enumerated().sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }.map(\.element)
		var last: Int?
		for action in sorted {
			let r = rank(action)
			if let last, last != r, r != 1 { menu.addItem(.separator()) }
			last = r
			let item = MenuAction(action.title) { [weak self] in self?.perform(action, version: version) }
			if let reason = action.disabledReason {
				item.isEnabled = false
				item.toolTip = reason
			}
			menu.addItem(item)
		}
		if actions.isEmpty {
			let item = NSMenuItem(title: Strings.codeActions.noActionsAvailable, action: nil, keyEquivalent: "")
			item.isEnabled = false
			menu.addItem(item)
		}
		let utf16 = editor.rope.utf16Offset(ofByte: offset)
		let screen = editor.firstRect(forCharacterRange: NSRange(location: utf16, length: 0), actualRange: nil)
		let rect = editor.convert(window.convertFromScreen(screen), from: nil)
		menu.popUp(positioning: nil, at: NSPoint(x: rect.minX, y: rect.maxY), in: editor)
	}

	func perform(_ action: CodeAction, version: Int) {
		guard let end = endpoint() else { return }
		let encoding = end.server.positionEncoding
		Task { [weak self] in
			do {
				let resolved = try await end.server.resolve(action)
				guard let self, let editor = self.editor else { return }
				if let edit = resolved.edit {
					guard editor.document.version == version else { return NSSound.beep() }
					if let problem = WorkspaceEditor.apply(edit, encoding: encoding) {
						return WorkspaceEditor.report(problem, in: editor.window)
					}
				}
				// A command's edits come back as workspace/applyEdit.
				if let command = resolved.command { try await end.server.execute(command) }
			} catch is CancellationError {
			} catch {
				WorkspaceEditor.report(Self.message(error), in: self?.editor?.window)
			}
		}
	}

	static func message(_ error: Error) -> String {
		(error as? RPCError)?.message ?? error.localizedDescription
	}

	// MARK: Formatting

	var canFormat: Bool { endpoint()?.server.supportsFormatting ?? false }

	/// Reformat Code (⌥⌘L): the lines of the selection, or the whole file without one.
	func format() {
		guard let editor, canFormat else { return NSSound.beep() }
		let selection = editor.selections.primary
		Task { [weak self] in
			do {
				try await self?.format(range: selection.isEmpty ? nil : selection.range)
			} catch is CancellationError {
			} catch {
				WorkspaceEditor.report(Self.message(error), in: self?.editor?.window)
			}
		}
	}

	/// Formats and applies the result as one undo step, unless the text changed meanwhile.
	/// Gives up after `timeout` seconds (saving must not wait on a stuck server).
	func format(range: Range<Int>?, timeout: Double? = nil) async throws {
		guard let editor, let end = endpoint(), end.server.supportsFormatting else { return }
		let rope = editor.rope, version = editor.document.version, settings = editor.format
		let server = end.server, uri = end.uri
		let request: @Sendable () async throws -> [(Range<Int>, String)]? = { try await server.format(uri: uri, range: range, in: rope, settings: settings) }
		let result: [(Range<Int>, String)]??
		if let timeout {
			result = try await withThrowingTaskGroup(of: [(Range<Int>, String)]??.self) { group in
				group.addTask { try await request() }
				group.addTask { try await Task.sleep(for: .seconds(timeout)); return .none }
				defer { group.cancelAll() }
				return try await group.next() ?? .none
			}
		} else {
			result = try await request()
		}
		guard case .some(let list) = result else { return } // timed out
		guard let list else { throw RPCError(code: 0, message: Strings.codeActions.formatterReturnedOverlappingChanges) }
		guard let editor = self.editor, editor.document.version == version else { return }
		editor.replace(list)
	}

	// MARK: Rename

	func rename() {
		guard let editor, let end = endpoint(), end.server.supportsRename, renameSheet == nil else { return NSSound.beep() }
		let rope = editor.rope, caret = editor.caret, version = editor.document.version
		generation += 1
		let gen = generation
		Task { [weak self] in
			let symbol: (range: Range<Int>, name: String)?
			do {
				symbol = try await end.server.prepareRename(uri: end.uri, offset: caret, in: rope)
			} catch is CancellationError {
				return
			} catch {
				guard let self, gen == generation else { return }
				return WorkspaceEditor.report(Self.message(error), in: self.editor?.window)
			}
			guard let self, gen == generation, let editor = self.editor, let window = editor.window,
			      editor.document.version == version else { return }
			guard let symbol else {
				return WorkspaceEditor.report(Strings.codeActions.cannotRename, in: window)
			}
			let root = (window.delegate as? DocumentWindow)?.project?.url
			let sheet = RenameSheet(name: symbol.name, root: root) { name in
				try await end.server.rename(uri: end.uri, offset: caret, in: rope, to: name)
			}
			sheet.encoding = end.server.positionEncoding
			sheet.onApply = { [weak self] edit in
				guard let editor = self?.editor else { return false }
				guard editor.document.version == version else {
					WorkspaceEditor.report(Strings.codeActions.fileChanged, in: editor.window)
					return false
				}
				if let problem = WorkspaceEditor.apply(edit, encoding: sheet.encoding) {
					WorkspaceEditor.report(problem, in: editor.window)
					return false
				}
				return true
			}
			sheet.onClose = { [weak self] in self?.renameSheet = nil }
			renameSheet = sheet
			sheet.begin(on: window)
		}
	}
}

/// The Rename sheet: the new name, below it every changed line as it will read, refreshed
/// while typing; Rename applies the change.
@MainActor
final class RenameSheet: NSObject, NSTextFieldDelegate, NSTableViewDataSource, NSTableViewDelegate {
	private struct Row {
		let url: URL
		let line: FileSearchLine
	}

	private let panel: NSPanel
	private let field = NSTextField()
	private let table = NSTableView()
	private let status = NSTextField(labelWithString: "")
	private let renameButton = NSButton()
	private let original: String
	private let root: URL?
	private let compute: @MainActor (String) async throws -> WorkspaceEdit?
	var encoding: PositionEncoding = .utf16
	var onApply: ((WorkspaceEdit) -> Bool)?
	var onClose: (() -> Void)?
	private var rows: [Row] = []
	private var edit: WorkspaceEdit?
	private var task: Task<Void, Never>?

	init(name: String, root: URL?, compute: @escaping @MainActor (String) async throws -> WorkspaceEdit?) {
		original = name
		self.root = root
		self.compute = compute
		panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 600, height: 380), styleMask: [.titled, .resizable], backing: .buffered, defer: true)
		super.init()
		panel.minSize = NSSize(width: 440, height: 280)
		let title = NSTextField(labelWithString: Strings.codeActions.renameSymbol(name: name))
		title.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
		title.lineBreakMode = .byTruncatingMiddle
		field.stringValue = name
		field.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
		field.delegate = self
		field.setAccessibilityLabel(Strings.codeActions.newName)
		let grid = NSGridView(views: [[NSTextField(labelWithString: Strings.common.newName), field]])
		grid.rowAlignment = .firstBaseline

		let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("Change"))
		table.addTableColumn(column)
		table.headerView = nil
		table.usesAutomaticRowHeights = false
		table.rowHeight = 20
		table.style = .plain
		table.dataSource = self
		table.delegate = self
		table.setAccessibilityLabel(Strings.codeActions.changes)
		let scroll = NSScrollView()
		scroll.documentView = table
		scroll.hasVerticalScroller = true
		scroll.borderType = .bezelBorder
		scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 160).isActive = true

		status.textColor = .secondaryLabelColor
		status.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
		status.lineBreakMode = .byTruncatingTail
		let note = NSTextField(wrappingLabelWithString: Strings.refactor.changesInfo)
		note.textColor = .secondaryLabelColor
		note.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
		note.setContentCompressionResistancePriority(.required, for: .vertical)

		renameButton.title = Strings.codeActions.rename
		renameButton.bezelStyle = .rounded
		renameButton.keyEquivalent = "\r"
		renameButton.target = self
		renameButton.action = #selector(apply(_:))
		renameButton.isEnabled = false
		let cancelButton = NSButton(title: Strings.common.cancel, target: self, action: #selector(cancel(_:)))
		cancelButton.keyEquivalent = "\u{1b}"
		let buttons = NSStackView(views: [status, NSView(), cancelButton, renameButton])
		status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

		let stack = NSStackView(views: [title, grid, scroll, note, buttons])
		stack.orientation = .vertical
		stack.alignment = .leading
		stack.spacing = 10
		stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
		for v in [title, grid, scroll, note, buttons] as [NSView] {
			v.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true
		}
		scroll.setContentHuggingPriority(.defaultLow, for: .vertical)
		panel.contentView = stack
	}

	func begin(on window: NSWindow) {
		window.beginSheet(panel)
		panel.makeFirstResponder(field)
		field.currentEditor()?.selectAll(nil)
		status.stringValue = Strings.codeActions.typeNewName
	}

	// MARK: Preview

	func controlTextDidChange(_ obj: Notification) { refresh() }

	/// For the language server check: types `name`, then the state of the preview.
	func type(_ name: String) {
		field.stringValue = name
		refresh()
	}
	var isReady: Bool { renameButton.isEnabled }
	var statusText: String { status.stringValue }
	var rowsForSnapshot: [String] { rows.map { NavigationController.path($0.url, root: root) + ":" + String($0.line.line + 1) + " " + $0.line.text } }
	func confirm() { apply(nil) }

	private func refresh() {
		task?.cancel()
		edit = nil
		renameButton.isEnabled = false
		let name = field.stringValue.trimmingCharacters(in: .whitespaces)
		guard !name.isEmpty, name != original else {
			show([], status: Strings.codeActions.typeNewName)
			return
		}
		status.stringValue = Strings.codeActions.lookingForChanges
		task = Task { [weak self] in
			try? await Task.sleep(for: .milliseconds(250)) // not a request per keystroke
			guard let self, !Task.isCancelled else { return }
			do {
				let edit = try await compute(name)
				guard !Task.isCancelled else { return }
				guard let edit, !edit.isEmpty else { return show([], status: Strings.codeActions.nothingToChange) }
				let rows = await Self.rows(edit, encoding: encoding)
				guard !Task.isCancelled else { return }
				self.edit = edit
				show(rows, status: Strings.codeActions.changeCount(count: edit.editCount) + " " + Strings.common.inFiles(count: edit.files.count))
				renameButton.isEnabled = !edit.hasFileOperations
				if edit.hasFileOperations { status.stringValue = Strings.codeActions.fileOperationsUnsupported }
			} catch is CancellationError {
			} catch {
				guard !Task.isCancelled else { return }
				show([], status: CodeActionController.message(error))
				status.textColor = .systemRed
			}
		}
	}

	private func show(_ rows: [Row], status text: String) {
		self.rows = rows
		table.reloadData()
		status.textColor = .secondaryLabelColor
		status.stringValue = text
	}

	/// The changed lines of every file (open files from their text, the rest from disk).
	private static func rows(_ edit: WorkspaceEdit, encoding: PositionEncoding) async -> [Row] {
		var open: [URL: Rope] = [:]
		for f in edit.files { if let url = f.url, let doc = FileDocument.document(for: url) { open[url] = doc.text.rope } }
		return await Task.detached(priority: .userInitiated) {
			var rows: [Row] = []
			for f in edit.files {
				guard let url = f.url else { continue }
				let rope: Rope
				if let r = open[url] { rope = r } else {
					guard let data = try? Data(contentsOf: url) else { continue }
					rope = Rope(bytes: [UInt8](data))
				}
				guard let list = rope.replacements(f.edits, encoding: encoding) else { continue }
				rows += rope.previewLines(list).map { Row(url: url, line: $0) }
			}
			return rows.sorted { ($0.url.path, $0.line.line) < ($1.url.path, $1.line.line) }
		}.value
	}

	func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

	func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
		let id = NSUserInterfaceItemIdentifier("ChangeRow")
		let cell = tableView.makeView(withIdentifier: id, owner: self) as? NSTableCellView ?? {
			let cell = NSTableCellView()
			cell.identifier = id
			let text = NSTextField(labelWithString: "")
			text.lineBreakMode = .byTruncatingTail
			text.translatesAutoresizingMaskIntoConstraints = false
			cell.addSubview(text)
			cell.textField = text
			NSLayoutConstraint.activate([
				text.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
				text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
				text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
			])
			return cell
		}()
		let r = rows[row]
		let small = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
		let mono = NSFont.monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
		let place = NavigationController.path(r.url, root: root) + ":" + String(r.line.line + 1) + "  "
		let text = NSMutableAttributedString(string: place, attributes: [.font: small, .foregroundColor: NSColor.secondaryLabelColor])
		// Marks are byte ranges of the line.
		let bytes = Array(r.line.text.utf8)
		var at = 0
		var leading = true
		for mark in r.line.ranges where mark.lowerBound >= at && mark.upperBound <= bytes.count {
			var before = String(decoding: bytes[at..<mark.lowerBound], as: UTF8.self)
			if leading { before = String(before.drop { $0 == " " || $0 == "\t" }) }
			leading = false
			text.append(NSAttributedString(string: before, attributes: [.font: mono, .foregroundColor: NSColor.labelColor]))
			text.append(NSAttributedString(string: String(decoding: bytes[mark], as: UTF8.self), attributes: [
				.font: NSFont.monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .bold),
				.foregroundColor: NSColor.labelColor,
				.backgroundColor: NSColor.findHighlightColor.withAlphaComponent(0.35),
			]))
			at = mark.upperBound
		}
		text.append(NSAttributedString(string: String(decoding: bytes[min(at, bytes.count)...], as: UTF8.self),
		                               attributes: [.font: mono, .foregroundColor: NSColor.labelColor]))
		cell.textField?.attributedStringValue = text
		return cell
	}

	func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }

	// MARK: Buttons

	@objc private func apply(_ sender: Any?) {
		guard let edit, onApply?(edit) ?? false else { return }
		close()
	}

	@objc private func cancel(_ sender: Any?) { close() }

	private func close() {
		task?.cancel()
		panel.sheetParent?.endSheet(panel)
		onClose?()
	}
}
