import AppKit

/// Find in Project (⇧⌘F): a section of the bottom panel shared by the project's tabs. The
/// searcher reads the files on disk (.gitignore respected) and streams results per file; files
/// with unsaved changes are searched here in their editor text. Selecting a line shows the
/// match in the editor, Return or a double click also moves the focus there. Replace All
/// changes open files in their editors (undoable, unsaved) and writes the others.
@MainActor
final class FindInFiles: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate, NSSearchFieldDelegate {
	let view = NSView()
	private let project: Project
	private let field = NSSearchField()
	private let replaceField = NSTextField()
	private let replaceButton = NSButton()
	private let scopeButton = NSPopUpButton()
	private let maskField = NSTextField()
	/// Folder (relative to the project) the search is limited to; set by Find in Folder.
	private(set) var folder = ""
	private let caseButton = FindBar.toggle("Aa", Strings.find.matchCase)
	private let wordButton = FindBar.toggle("W", Strings.find.wholeWord)
	private let regexButton = FindBar.toggle(".*", Strings.find.regularExpression)
	private let status = NSTextField(labelWithString: "")
	private let outline = ResultsOutline()

	private final class FileItem {
		var result: FileSearchResult
		var lines: [LineItem] = []
		init(_ result: FileSearchResult) { self.result = result }
	}

	private final class LineItem {
		unowned let file: FileItem
		let index: Int
		init(_ file: FileItem, _ index: Int) { self.file = file; self.index = index }
	}

	private var files: [FileItem] = []
	private var pending: [FileSearchResult] = []
	private var flushScheduled = false
	private var task: Task<Void, Never>?
	private var generation = 0
	private var options = FileSearchOptions(query: "")
	private var running = false
	private var summary = FileSearchSummary()
	private var errorText: String?
	private var typing = 0

	init(project: Project) {
		self.project = project
		super.init()
		build()
		updateStatus()
	}

	// MARK: Layout

	private func build() {
		field.placeholderString = Strings.findInFiles.title
		field.setAccessibilityLabel(Strings.findInFiles.title)
		field.delegate = self
		field.sendsWholeSearchString = true
		field.sendsSearchStringImmediately = false
		field.target = self
		field.action = #selector(searchNow(_:))
		replaceField.placeholderString = Strings.common.replace
		replaceField.setAccessibilityLabel(Strings.common.replace)
		replaceButton.title = Strings.findInFiles.replaceAll
		replaceButton.bezelStyle = .rounded
		replaceButton.controlSize = .small
		replaceButton.target = self
		replaceButton.action = #selector(replaceAll(_:))
		scopeButton.controlSize = .small
		scopeButton.target = self
		scopeButton.action = #selector(optionsChanged(_:))
		scopeButton.setAccessibilityLabel(Strings.findInFiles.scopeProject)
		maskField.placeholderString = Strings.findInFiles.fileMask
		maskField.setAccessibilityLabel(Strings.findInFiles.fileMask)
		maskField.delegate = self
		maskField.target = self
		maskField.action = #selector(searchNow(_:))
		rebuildScopes()
		for b in [caseButton, wordButton, regexButton] {
			b.target = self
			b.action = #selector(optionsChanged(_:))
		}
		status.textColor = .secondaryLabelColor
		status.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
		status.lineBreakMode = .byTruncatingTail
		status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

		let column = NSTableColumn(identifier: .init("result"))
		outline.addTableColumn(column)
		outline.outlineTableColumn = column
		outline.headerView = nil
		outline.style = .plain
		outline.rowSizeStyle = .small
		outline.usesAutomaticRowHeights = false
		outline.rowHeight = 20
		outline.dataSource = self
		outline.delegate = self
		outline.target = self
		outline.action = #selector(rowClicked(_:))
		outline.doubleAction = #selector(rowOpened(_:))
		outline.onReturn = { [weak self] in self?.openSelected(focusEditor: true) }
		outline.onDelete = { [weak self] in self?.removeSelected() }
		outline.setAccessibilityLabel(Strings.findInFiles.searchResults)
		let scroll = NSScrollView()
		scroll.documentView = outline
		scroll.hasVerticalScroller = true
		scroll.autohidesScrollers = true
		scroll.drawsBackground = false

		let findRow = NSStackView(views: [field, caseButton, wordButton, regexButton])
		let replaceRow = NSStackView(views: [replaceField, replaceButton])
		let scopeRow = NSStackView(views: [scopeButton, maskField])
		for row in [findRow, replaceRow, scopeRow] { row.spacing = 6 }
		let top = NSStackView(views: [findRow, replaceRow, scopeRow, status])
		top.orientation = .vertical
		top.alignment = .leading
		top.spacing = 6
		for v in [top, scroll] as [NSView] {
			v.translatesAutoresizingMaskIntoConstraints = false
			view.addSubview(v)
		}
		NSLayoutConstraint.activate([
			top.topAnchor.constraint(equalTo: view.topAnchor, constant: 8),
			top.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
			top.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
			findRow.widthAnchor.constraint(equalTo: top.widthAnchor),
			replaceRow.widthAnchor.constraint(equalTo: top.widthAnchor),
			scopeRow.widthAnchor.constraint(equalTo: top.widthAnchor),
			replaceField.widthAnchor.constraint(equalTo: field.widthAnchor),
			scroll.topAnchor.constraint(equalTo: top.bottomAnchor, constant: 6),
			scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
			scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
			scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
		])
	}

	private static let projectScope = 0, openFilesScope = 1, folderScope = 2

	private func rebuildScopes() {
		scopeButton.removeAllItems()
		scopeButton.addItems(withTitles: [Strings.findInFiles.scopeProject, Strings.findInFiles.scopeOpenFiles])
		if !folder.isEmpty { scopeButton.addItem(withTitle: Strings.findInFiles.scopeFolder(folder: folder)) }
		scopeButton.selectItem(at: folder.isEmpty ? Self.projectScope : Self.folderScope)
	}

	/// Limits the search to `folder` (relative path) and focuses the field.
	func focus(folder: String) {
		self.folder = folder
		rebuildScopes()
		focus(query: nil)
		searchNow(nil)
	}

	/// Puts the focus into the search field; `query` (the editor's selection) replaces its text.
	func focus(query: String?) {
		if let query, !query.isEmpty, !query.contains("\n") {
			field.stringValue = query
			searchNow(nil)
		}
		view.window?.makeFirstResponder(field)
		field.currentEditor()?.selectAll(nil)
	}

	// Snapshot mode.
	var isIdle: Bool { !running && !flushScheduled }
	var statusText: String { status.stringValue }
	var rowsForSnapshot: [String] {
		(0..<outline.numberOfRows).map { row in
			switch outline.item(atRow: row) {
			case let f as FileItem: f.result.path
			case let l as LineItem: "    " + Self.lineText(l.file.result.lines[l.index]).string
			default: ""
			}
		}
	}

	// MARK: Searching

	func controlTextDidChange(_ obj: Notification) {
		guard (obj.object as? NSSearchField) === field || (obj.object as? NSTextField) === maskField else { return }
		// Searching while typing, after a short pause; an empty field clears the results.
		typing += 1
		let typed = typing
		DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
			guard let self, typed == typing else { return }
			searchNow(nil)
		}
	}

	@objc private func optionsChanged(_ sender: Any?) { searchNow(nil) }

	@objc private func searchNow(_ sender: Any?) {
		var o = FileSearchOptions(query: field.stringValue, regex: regexButton.state == .on,
		                          caseSensitive: caseButton.state == .on, wholeWord: wordButton.state == .on)
		o.mask = maskField.stringValue
		switch scopeButton.indexOfSelectedItem {
		case Self.openFilesScope:
			o.only = FileDocument.all.compactMap { doc in
				doc.url.flatMap { project.paths.relative($0.standardizedFileURL.path) }.flatMap { $0.isEmpty ? nil : $0 }
			}
		case Self.folderScope: o.folder = folder
		default: break
		}
		guard sender != nil || o != options || !running else { return }
		task?.cancel()
		generation += 1
		files = []
		pending = []
		summary = FileSearchSummary()
		errorText = nil
		outline.reloadData()
		options = o
		guard !o.query.isEmpty else {
			running = false
			return updateStatus()
		}
		// Files with unsaved changes: their editor text, not the disk.
		let query = findQuery
		var local: [FileSearchResult] = []
		let mask = PathMask(o.mask)
		for doc in FileDocument.all where doc.isEdited {
			guard let url = doc.url, let rel = project.paths.relative(url.standardizedFileURL.path), !rel.isEmpty else { continue }
			guard rel.hasPrefix(o.folder.isEmpty ? "" : o.folder + "/"), mask.matches(rel), o.only?.contains(rel) ?? true else { continue }
			o.skip.append(rel)
			do {
				if let r = try Self.search(doc.text.rope, path: rel, query: query) { local.append(r) }
			} catch {
				errorText = error is FindError ? Strings.findInFiles.invalidRegularExpression : error.localizedDescription
				return updateStatus()
			}
		}
		running = true
		updateStatus()
		receive(local)
		let gen = generation, root = project.url, options = o
		let sink = ResultSink(self)
		task = Task { [weak self] in
			do {
				let s = try await FileSearcher.search(root: root, options) { result in
					Task { @MainActor in sink.owner?.receive([result], generation: gen) }
				}
				self?.finish(s, generation: gen)
			} catch is CancellationError {
			} catch {
				self?.fail(error, generation: gen)
			}
		}
	}

	private var findQuery: FindQuery {
		FindQuery(text: options.query, regex: options.regex, caseSensitive: options.caseSensitive, wholeWord: options.wholeWord)
	}

	fileprivate func receive(_ results: [FileSearchResult], generation gen: Int? = nil) {
		guard gen == nil || gen == generation else { return }
		pending += results
		guard !flushScheduled else { return }
		flushScheduled = true
		// Results are shown in batches (streaming thousands of files row by row is slow).
		DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in self?.flush() }
	}

	private func flush() {
		flushScheduled = false
		guard !pending.isEmpty else { return }
		for r in pending {
			let item = FileItem(r)
			item.lines = r.lines.indices.map { LineItem(item, $0) }
			var lo = 0, hi = files.count // sorted by path
			while lo < hi {
				let mid = (lo + hi) / 2
				if files[mid].result.path.localizedStandardCompare(r.path) == .orderedDescending { hi = mid } else { lo = mid + 1 }
			}
			files.insert(item, at: lo)
		}
		pending = []
		let selected = outline.item(atRow: outline.selectedRow)
		outline.reloadData()
		outline.expandItem(nil, expandChildren: true)
		if let selected { outline.selectRowIndexes([outline.row(forItem: selected)], byExtendingSelection: false) }
		updateStatus()
	}

	private func finish(_ s: FileSearchSummary, generation gen: Int) {
		guard gen == generation else { return }
		flush()
		running = false
		summary = s
		updateStatus()
	}

	private func fail(_ error: Error, generation gen: Int) {
		guard gen == generation else { return }
		running = false
		errorText = error is FileSearchError ? Strings.findInFiles.invalidRegularExpression : error.localizedDescription
		updateStatus()
	}

	private func updateStatus() {
		let matches = files.reduce(0) { $0 + $1.result.matchCount }
		if let errorText {
			status.stringValue = errorText
			status.textColor = .systemRed
			return
		}
		status.textColor = .secondaryLabelColor
		if options.query.isEmpty {
			status.stringValue = Strings.findInFiles.prompt
		} else if running {
			status.stringValue = Strings.findInFiles.searching + (matches > 0 ? " " + Strings.find.matchCount(count: matches) : "")
		} else if files.isEmpty {
			status.stringValue = Strings.findInFiles.noResults
		} else {
			status.stringValue = Strings.find.matchCount(count: matches) + " " + Strings.common.inFiles(count: files.count)
				+ (summary.truncated ? " " + Strings.findInFiles.tooManyMatches : "")
		}
		replaceButton.isEnabled = !running && !files.isEmpty
	}

	/// Matches in an editor's text, grouped by line like the helper's.
	static func search(_ rope: Rope, path: String, query: FindQuery) throws -> FileSearchResult? {
		let matches = try rope.matches(of: query, limit: 20_000)
		guard !matches.isEmpty else { return nil }
		var lines: [FileSearchLine] = []
		var current: (line: Int, start: Int, end: Int, ranges: [Range<Int>])?
		func close() {
			guard let c = current else { return }
			var text = rope.bytes(in: c.start..<c.end)
			if text.last == 0x0D { text.removeLast() }
			var column = 0
			if text.count > 400, let first = c.ranges.first {
				column = max(0, first.lowerBound - 100)
				while column > 0, text[column] & 0xC0 == 0x80 { column -= 1 }
				var cut = min(text.count, column + 400)
				while cut < text.count, text[cut] & 0xC0 == 0x80 { cut -= 1 }
				text = Array(text[column..<cut])
			}
			let ranges = c.ranges.map { ($0.lowerBound - column)..<min($0.upperBound - column, text.count) }.filter { $0.lowerBound >= 0 && !$0.isEmpty }
			lines.append(FileSearchLine(line: c.line, column: column, text: String(decoding: text, as: UTF8.self), ranges: ranges))
		}
		for m in matches where !m.isEmpty {
			let line = rope.line(containing: m.lowerBound)
			if current?.line != line {
				close()
				let range = rope.lineRange(line)
				var end = range.upperBound
				if end > range.lowerBound, rope.byte(at: end - 1) == 0x0A { end -= 1 }
				current = (line, range.lowerBound, end, [])
			}
			if let start = current?.start, let end = current?.end {
				current?.ranges.append((m.lowerBound - start)..<(min(m.upperBound, end) - start))
			}
		}
		close()
		return FileSearchResult(path: path, lines: lines)
	}

	// MARK: Opening results

	@objc private func rowClicked(_ sender: Any?) {
		guard outline.clickedRow >= 0 else { return }
		openSelected(focusEditor: false)
	}

	@objc private func rowOpened(_ sender: Any?) { openSelected(focusEditor: true) }

	func outlineViewSelectionDidChange(_ notification: Notification) {
		// Keyboard moves show the match too (the focus stays here).
		// Browsing with the arrow keys is not a jump of its own (Back returns to where it began).
		if NSApp.currentEvent?.type == .keyDown { openSelected(focusEditor: false, record: false) }
	}

	private func openSelected(focusEditor: Bool, record: Bool = true) {
		let item = outline.item(atRow: outline.selectedRow)
		let url: URL, line: FileSearchLine?
		if let l = item as? LineItem {
			url = project.url.appendingPathComponent(l.file.result.path)
			line = l.file.result.lines[l.index]
		} else if let f = item as? FileItem {
			url = project.url.appendingPathComponent(f.result.path)
			line = f.result.lines.first
		} else { return }
		guard let app = NSApp.delegate as? AppDelegate else { return }
		if record { (view.window?.delegate as? DocumentWindow)?.recordJump() }
		app.open(url)
		guard let doc = FileDocument.document(for: url), let editor = doc.text.views.first(where: { $0.window?.isKeyWindow == true }) ?? doc.text.views.first else { return }
		if let line {
			let rope = editor.rope
			let start = rope.offset(ofLine: min(line.line, rope.lineCount - 1)) + line.column
			let r = line.ranges.first ?? 0..<0
			editor.reveal((start + r.lowerBound)..<(start + r.upperBound))
		}
		if focusEditor {
			editor.window?.makeFirstResponder(editor)
		} else {
			// The panel moves with the tab in front; keep browsing results there.
			DispatchQueue.main.async { [weak self] in
				guard let self, let window = view.window else { return }
				window.makeFirstResponder(outline)
			}
		}
	}

	/// Delete: drops a file or line from the results (Replace All skips dropped files).
	private func removeSelected() {
		let row = outline.selectedRow
		switch outline.item(atRow: row) {
		case let f as FileItem:
			files.removeAll { $0 === f }
		case let l as LineItem:
			let f = l.file
			f.result.lines.remove(at: l.index)
			f.lines = f.result.lines.indices.map { LineItem(f, $0) }
			if f.lines.isEmpty { files.removeAll { $0 === f } }
		default: return
		}
		outline.reloadData()
		outline.expandItem(nil, expandChildren: true)
		outline.selectRowIndexes([min(row, outline.numberOfRows - 1)], byExtendingSelection: false)
		updateStatus()
	}

	// MARK: Replacing

	@objc private func replaceAll(_ sender: Any?) {
		guard !files.isEmpty, let window = view.window else { return }
		let matches = files.reduce(0) { $0 + $1.result.matchCount }
		let alert = NSAlert()
		alert.messageText = Strings.findInFiles.replaceConfirmation(matches: Strings.find.matchCount(count: matches) + " " + Strings.common.inFiles(count: files.count), replacement: replaceField.stringValue)
		alert.informativeText = Strings.refactor.changesInfo
		alert.accessoryView = previewView()
		alert.addButton(withTitle: Strings.common.replace)
		alert.addButton(withTitle: Strings.common.cancel)
		alert.beginSheetModal(for: window) { response in
			MainActor.assumeIsolated {
				if response == .alertFirstButtonReturn { self.performReplace() }
			}
		}
	}

	/// Before and after of the lines Replace All will change (the first few hundred).
	private func previewView() -> NSView {
		let query = findQuery, template = replaceField.stringValue
		let font = NSFont.monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
		let text = NSMutableAttributedString()
		func add(_ s: String, _ attrs: [NSAttributedString.Key: Any]) {
			text.append(NSAttributedString(string: s + "\n", attributes: [.font: font].merging(attrs) { $1 }))
		}
		var shown = 0, total = 0
		for f in files {
			total += f.result.lines.count
			guard shown < Self.previewLimit else { continue }
			add(f.result.path, [.font: NSFont.boldSystemFont(ofSize: NSFont.smallSystemFontSize)])
			for line in f.result.lines where shown < Self.previewLimit {
				shown += 1
				let old = line.text.trimmingCharacters(in: .whitespaces)
				let new = (try? Rope.replacing(in: line.text, query: query, with: template))?.trimmingCharacters(in: .whitespaces) ?? old
				add("\(line.line + 1)  − " + old, [.foregroundColor: NSColor.systemRed])
				add("\(line.line + 1)  + " + new, [.foregroundColor: NSColor.systemGreen])
			}
		}
		if total > shown { add(Strings.findInFiles.previewMore(count: total - shown), [.foregroundColor: NSColor.secondaryLabelColor]) }
		let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 560, height: 260))
		textView.isEditable = false
		textView.drawsBackground = false
		textView.textStorage?.setAttributedString(text)
		textView.autoresizingMask = [.width]
		textView.isHorizontallyResizable = true
		textView.textContainer?.widthTracksTextView = false
		textView.textContainer?.containerSize = NSSize(width: 100_000, height: CGFloat.greatestFiniteMagnitude)
		let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 560, height: 260))
		scroll.documentView = textView
		scroll.hasVerticalScroller = true
		scroll.hasHorizontalScroller = true
		scroll.borderType = .bezelBorder
		return scroll
	}

	private static let previewLimit = 300

	private func performReplace() {
		let query = findQuery, template = replaceField.stringValue
		var failed: [String] = []
		for f in files {
			let url = project.url.appendingPathComponent(f.result.path)
			// Only the lines still listed (lines removed from the results stay as they are).
			let lines = Set(f.result.lines.map(\.line))
			do {
				try FileDocument.replace(in: url) { rope in
					try rope.replacements(of: query, with: template, preserveCase: false)
						.filter { lines.contains(rope.line(containing: $0.0.lowerBound)) }
				}
			} catch {
				failed.append(f.result.path)
			}
		}
		searchNow(self)
		if !failed.isEmpty, let window = view.window {
			let alert = NSAlert()
			alert.messageText = Strings.refactor.someFilesFailed
			alert.informativeText = failed.prefix(10).joined(separator: "\n")
			alert.beginSheetModal(for: window)
		}
	}

	// MARK: Outline

	func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
		if item == nil { return files.count }
		return (item as? FileItem)?.lines.count ?? 0
	}

	func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
		if let f = item as? FileItem { return f.lines[index] }
		return files[index]
	}

	func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool { item is FileItem }

	func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
		let id = NSUserInterfaceItemIdentifier(item is FileItem ? "FileRow" : "LineRow")
		let cell = outlineView.makeView(withIdentifier: id, owner: self) as? NSTableCellView ?? Self.cell(id, icon: item is FileItem)
		if let f = item as? FileItem {
			let url = project.url.appendingPathComponent(f.result.path)
			cell.imageView?.image = NSWorkspace.shared.icon(forFile: url.path)
			let text = NSMutableAttributedString(string: url.lastPathComponent, attributes: [.font: NSFont.boldSystemFont(ofSize: NSFont.smallSystemFontSize)])
			let folder = (f.result.path as NSString).deletingLastPathComponent
			let rest = (folder.isEmpty ? "" : "  " + folder) + "  " + String(f.result.matchCount)
			text.append(NSAttributedString(string: rest, attributes: [.font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize), .foregroundColor: NSColor.secondaryLabelColor]))
			cell.textField?.attributedStringValue = text
			cell.setAccessibilityLabel(f.result.path)
		} else if let l = item as? LineItem {
			cell.textField?.attributedStringValue = Self.lineText(l.file.result.lines[l.index])
		}
		return cell
	}

	static func cell(_ id: NSUserInterfaceItemIdentifier, icon: Bool) -> NSTableCellView {
		let cell = NSTableCellView()
		cell.identifier = id
		let text = NSTextField(labelWithString: "")
		text.lineBreakMode = .byTruncatingTail
		text.translatesAutoresizingMaskIntoConstraints = false
		cell.addSubview(text)
		cell.textField = text
		var leading = cell.leadingAnchor
		if icon {
			let image = NSImageView()
			image.translatesAutoresizingMaskIntoConstraints = false
			cell.addSubview(image)
			cell.imageView = image
			NSLayoutConstraint.activate([
				image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
				image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
				image.widthAnchor.constraint(equalToConstant: 16),
				image.heightAnchor.constraint(equalToConstant: 16),
			])
			leading = image.trailingAnchor
		}
		NSLayoutConstraint.activate([
			text.leadingAnchor.constraint(equalTo: leading, constant: 4),
			text.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -4),
			text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
		])
		return cell
	}

	/// "42  text" with the matches marked; leading indentation dropped.
	static func lineText(_ line: FileSearchLine) -> NSAttributedString {
		let font = NSFont.monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
		let result = NSMutableAttributedString(string: String(line.line + 1) + "  ", attributes: [
			.font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular),
			.foregroundColor: NSColor.secondaryLabelColor,
		])
		let bytes = Array(line.text.utf8)
		let indent = bytes.prefix { $0 == 0x20 || $0 == 0x09 }.count
		let body = String(decoding: bytes[indent...], as: UTF8.self)
		let start = result.length
		result.append(NSAttributedString(string: body, attributes: [.font: font, .foregroundColor: NSColor.labelColor]))
		for r in line.ranges where r.lowerBound >= indent && r.upperBound <= bytes.count {
			let lo = String(decoding: bytes[indent..<r.lowerBound], as: UTF8.self).utf16.count
			let len = String(decoding: bytes[r], as: UTF8.self).utf16.count
			result.addAttributes([.backgroundColor: NSColor.findHighlightColor.withAlphaComponent(0.6),
			                      .foregroundColor: NSColor.black], range: NSRange(location: start + lo, length: len))
		}
		return result
	}
}

/// Main-actor reference the helper's background callbacks can carry.
@MainActor
private final class ResultSink {
	weak var owner: FindInFiles?
	init(_ owner: FindInFiles) { self.owner = owner }
}

/// Return opens the selected result, Delete drops it.
final class ResultsOutline: NSOutlineView {
	var onReturn: (() -> Void)?
	var onDelete: (() -> Void)?

	override func keyDown(with event: NSEvent) {
		switch event.keyCode {
		case 36, 76: onReturn?()
		case 51, 117: onDelete?()
		default: super.keyDown(with: event)
		}
	}
}
