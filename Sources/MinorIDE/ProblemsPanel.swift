import AppKit
import EditorKit
import LSPKit
import MinorCore
import TextEngine

/// Problems (plan 3.7): a section of the bottom panel with the language server's errors,
/// warnings and notes by file. Problems of open files follow their edits; selecting one shows
/// it in the editor, Return or a double click also moves the focus there.
@MainActor
final class ProblemsPanel: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
	let view = NSView()
	private let project: Project
	private let status = NSTextField(labelWithString: "")
	private let outline = ResultsOutline()

	private final class FileItem {
		let url: URL
		let path: String
		var problems: [ProblemItem] = []
		init(_ url: URL, _ path: String) { self.url = url; self.path = path }
	}

	private final class ProblemItem {
		unowned let file: FileItem
		let severity: EditorDiagnostic.Severity
		let message: String
		let source: String?
		/// 1-based, as shown.
		let line: Int, column: Int
		/// Bytes in the open document, or the server's range for a file that is not open.
		let range: Range<Int>?
		let lspRange: LSPRange?
		init(_ file: FileItem, severity: EditorDiagnostic.Severity, message: String, source: String?, line: Int, column: Int,
		     range: Range<Int>?, lspRange: LSPRange?) {
			self.file = file
			self.severity = severity
			self.message = message
			self.source = source
			self.line = line
			self.column = column
			self.range = range
			self.lspRange = lspRange
		}
	}

	private var files: [FileItem] = []
	private var observer: NSObjectProtocol?
	private var reloadPending = false

	init(project: Project) {
		self.project = project
		super.init()
		build()
		project.languageServers.onProblems.append { [weak self] in self?.scheduleReload() }
		observer = NotificationCenter.default.addObserver(forName: FileDocument.textDidChange, object: nil, queue: .main) { [weak self] note in
			guard let doc = note.object as? FileDocument else { return }
			MainActor.assumeIsolated {
				if doc.text.hasDiagnostics { self?.scheduleReload() }
			}
		}
		reload()
	}

	private func build() {
		status.textColor = .secondaryLabelColor
		status.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
		status.lineBreakMode = .byTruncatingTail
		status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
		let column = NSTableColumn(identifier: .init("problem"))
		outline.addTableColumn(column)
		outline.outlineTableColumn = column
		outline.headerView = nil
		outline.style = .plain
		outline.rowSizeStyle = .small
		outline.rowHeight = 20
		outline.dataSource = self
		outline.delegate = self
		outline.target = self
		outline.action = #selector(rowClicked(_:))
		outline.doubleAction = #selector(rowOpened(_:))
		outline.onReturn = { [weak self] in self?.openSelected(focusEditor: true) }
		outline.setAccessibilityLabel(L("Problems"))
		let scroll = NSScrollView()
		scroll.documentView = outline
		scroll.hasVerticalScroller = true
		scroll.autohidesScrollers = true
		scroll.drawsBackground = false
		for v in [status, scroll] as [NSView] {
			v.translatesAutoresizingMaskIntoConstraints = false
			view.addSubview(v)
		}
		NSLayoutConstraint.activate([
			status.topAnchor.constraint(equalTo: view.topAnchor, constant: 8),
			status.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
			status.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -8),
			scroll.topAnchor.constraint(equalTo: status.bottomAnchor, constant: 6),
			scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
			scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
			scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
		])
	}

	/// Reloads once after the current burst (a publish per file, typing).
	private func scheduleReload() {
		guard !reloadPending else { return }
		reloadPending = true
		DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
			MainActor.assumeIsolated {
				self?.reloadPending = false
				self?.reload()
			}
		}
	}

	/// Files with problems by path; hints are left out (they are only dotted in the editor).
	func reload() {
		let services = project.languageServers
		var byURL: [URL: FileItem] = [:]
		func file(_ url: URL) -> FileItem {
			if let f = byURL[url] { return f }
			let f = FileItem(url, NavigationController.path(url, root: project.url))
			byURL[url] = f
			return f
		}
		var tracked: Set<URL> = []
		for doc in FileDocument.all where services.isTracking(doc) {
			guard let url = doc.url?.standardizedFileURL else { continue }
			tracked.insert(url)
			let rope = doc.text.rope
			for d in doc.text.diagnostics where d.severity != .hint {
				let f = file(url), line = rope.line(containing: d.range.lowerBound)
				let column = rope.utf16Offset(ofByte: d.range.lowerBound) - rope.utf16Offset(ofByte: rope.offset(ofLine: line)) + 1
				f.problems.append(ProblemItem(f, severity: d.severity, message: d.message, source: d.source, line: line + 1, column: column,
				                              range: d.range, lspRange: nil))
			}
		}
		for (uri, report) in services.problems {
			guard let url = URL(string: uri)?.standardizedFileURL, url.isFileURL, !tracked.contains(url) else { continue }
			for d in report.diagnostics where d.severity != .hint {
				let f = file(url)
				f.problems.append(ProblemItem(f, severity: EditorDiagnostic.Severity(rawValue: d.severity.rawValue) ?? .error, message: d.message,
				                              source: d.source, line: d.range.start.line + 1, column: d.range.start.character + 1,
				                              range: nil, lspRange: d.range))
			}
		}
		for f in byURL.values { f.problems.sort { ($0.line, $0.column, $0.severity) < ($1.line, $1.column, $1.severity) } }
		// Keep the selected problem selected.
		let selected = (outline.item(atRow: outline.selectedRow) as? ProblemItem).map { ($0.file.url, $0.line, $0.message) }
		files = byURL.values.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
		outline.reloadData()
		outline.expandItem(nil, expandChildren: true)
		if let selected, let item = files.first(where: { $0.url == selected.0 })?.problems.first(where: { $0.line == selected.1 && $0.message == selected.2 }) {
			outline.selectRowIndexes([outline.row(forItem: item)], byExtendingSelection: false)
		}
		updateStatus()
	}

	private func updateStatus() {
		let all = files.flatMap(\.problems)
		let errors = all.count { $0.severity == .error }, warnings = all.count { $0.severity == .warning }
		let notes = all.count - errors - warnings
		let old = status.stringValue
		if all.isEmpty {
			if case .server(.running) = project.languageServers.status {
				status.stringValue = L("No problems.")
			} else {
				status.stringValue = L("Errors and warnings from the language server will appear here.")
			}
		} else {
			var parts: [String] = []
			if errors > 0 { parts.append(LP("%d errors", one: "%d error", errors)) }
			if warnings > 0 { parts.append(LP("%d warnings", one: "%d warning", warnings)) }
			if notes > 0 { parts.append(LP("%d notes", one: "%d note", notes)) }
			status.stringValue = parts.joined(separator: ", ") + " " + LP("in %d files", one: "in %d file", files.count)
		}
		if status.stringValue != old { NSAccessibility.post(element: status, notification: .valueChanged) }
	}

	// Snapshot mode.
	var statusText: String { status.stringValue }
	var rowsForSnapshot: [String] {
		(0..<outline.numberOfRows).map { row in
			switch outline.item(atRow: row) {
			case let f as FileItem: f.path
			case let p as ProblemItem: "    \(p.line):\(p.column) \(p.message)"
			default: ""
			}
		}
	}

	// MARK: Opening

	@objc private func rowClicked(_ sender: Any?) {
		guard outline.clickedRow >= 0 else { return }
		openSelected(focusEditor: false)
	}

	@objc private func rowOpened(_ sender: Any?) { openSelected(focusEditor: true) }

	func outlineViewSelectionDidChange(_ notification: Notification) {
		if NSApp.currentEvent?.type == .keyDown { openSelected(focusEditor: false, record: false) }
	}

	private func openSelected(focusEditor: Bool, record: Bool = true) {
		let problem: ProblemItem
		switch outline.item(atRow: outline.selectedRow) {
		case let p as ProblemItem: problem = p
		case let f as FileItem:
			guard let first = f.problems.first else { return }
			problem = first
		default: return
		}
		guard let app = NSApp.delegate as? AppDelegate else { return }
		if record { (view.window?.delegate as? DocumentWindow)?.recordJump() }
		app.open(problem.file.url, from: project)
		guard let doc = FileDocument.document(for: problem.file.url),
		      let editor = doc.text.views.first(where: { $0.window?.isKeyWindow == true }) ?? doc.text.views.first else { return }
		let rope = doc.text.rope
		let start: Int
		if let range = problem.range {
			start = range.lowerBound
		} else if let lsp = problem.lspRange {
			start = rope.byteOffset(of: lsp.start, encoding: project.languageServers.positionEncoding)
		} else {
			return
		}
		editor.reveal(start..<start)
		if focusEditor {
			editor.window?.makeFirstResponder(editor)
		} else {
			DispatchQueue.main.async { [weak self] in
				guard let self, let window = view.window else { return }
				window.makeFirstResponder(outline)
			}
		}
	}

	// MARK: Outline

	func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
		if item == nil { return files.count }
		return (item as? FileItem)?.problems.count ?? 0
	}

	func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
		if let f = item as? FileItem { return f.problems[index] }
		return files[index]
	}

	func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool { item is FileItem }

	func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
		let id = NSUserInterfaceItemIdentifier(item is FileItem ? "FileRow" : "ProblemRow")
		let cell = outlineView.makeView(withIdentifier: id, owner: self) as? NSTableCellView ?? FindInFiles.cell(id, icon: true)
		let small = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
		if let f = item as? FileItem {
			cell.imageView?.image = NSWorkspace.shared.icon(forFile: f.url.path)
			let text = NSMutableAttributedString(string: f.url.lastPathComponent, attributes: [.font: NSFont.boldSystemFont(ofSize: NSFont.smallSystemFontSize)])
			let folder = (f.path as NSString).deletingLastPathComponent
			let rest = (folder.isEmpty ? "" : "  " + folder) + "  " + String(f.problems.count)
			text.append(NSAttributedString(string: rest, attributes: [.font: small, .foregroundColor: NSColor.secondaryLabelColor]))
			cell.textField?.attributedStringValue = text
			cell.toolTip = nil
			cell.setAccessibilityLabel(f.path)
		} else if let p = item as? ProblemItem {
			let (symbol, label) = HoverController.severitySymbol(p.severity)
			let color = EditorDiagnostic(range: 0..<0, severity: p.severity, message: "").color
			cell.imageView?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)?
				.withSymbolConfiguration(.init(paletteColors: [color]))
			let message = p.message.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? p.message
			let text = NSMutableAttributedString(string: message, attributes: [.font: small])
			var detail = "  " + L("line %d, column %d", p.line, p.column)
			if let source = p.source, !source.isEmpty { detail = "  " + source + detail }
			text.append(NSAttributedString(string: detail, attributes: [.font: small, .foregroundColor: NSColor.secondaryLabelColor]))
			cell.textField?.attributedStringValue = text
			cell.toolTip = p.message
			cell.setAccessibilityLabel(label + ", " + p.message + ", " + L("line %d, column %d", p.line, p.column))
		}
		return cell
	}
}
