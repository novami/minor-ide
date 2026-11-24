import AppKit

/// Find Usages (⌥F7): a section of the bottom panel shared by the project's tabs, with the
/// usages from the language server by file. Selecting a line shows it in the editor, Return
/// or a double click also moves the focus there. Places in open files follow their edits
/// (anchors), so the list and the jumps stay right while you change the code.
@MainActor
final class UsagesPanel: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
	let view = NSView()
	private let project: Project
	private let status = NSTextField(labelWithString: "")
	private let outline = ResultsOutline()

	private final class FileItem {
		let url: URL
		let path: String
		var lines: [LineItem] = []
		/// The open document whose anchors the lines follow.
		weak var doc: FileDocument?
		init(_ url: URL, _ path: String) { self.url = url; self.path = path }
	}

	@MainActor private final class LineItem {
		unowned let file: FileItem
		let found: NavigationTarget
		var anchors: (start: AnchorID, end: AnchorID)?
		init(_ file: FileItem, _ target: NavigationTarget) { self.file = file; self.found = target }

		/// Where the usage is now: moved by the edits of the open file since the search.
		var target: NavigationTarget {
			guard let anchors, let rope = file.doc?.text.rope, let lo = file.doc?.text.anchors.offset(of: anchors.start),
			      let hi = file.doc?.text.anchors.offset(of: anchors.end), hi <= rope.byteCount else { return found }
			return NavigationTarget(url: file.url, bytes: lo..<max(lo, hi), in: rope)
		}
	}

	private var files: [FileItem] = []
	private var name = ""
	private var observer: NSObjectProtocol?
	private var refreshPending: Set<ObjectIdentifier> = []
	private var generation = 0
	private(set) var isSearching = false

	init(project: Project) {
		self.project = project
		super.init()
		build()
		status.stringValue = Strings.usages.emptyHint
		observer = NotificationCenter.default.addObserver(forName: FileDocument.textDidChange, object: nil, queue: .main) { [weak self] note in
			guard let doc = note.object as? FileDocument else { return }
			let id = ObjectIdentifier(doc)
			MainActor.assumeIsolated { self?.textChanged(id) }
		}
	}

	/// Anchors in the open file: the lines follow its edits from now on. The positions must
	/// fit its text (found in it, or the file was just loaded from disk).
	private func track(_ f: FileItem) {
		guard f.doc == nil, let doc = FileDocument.document(for: f.url) else { return }
		f.doc = doc
		for l in f.lines {
			l.anchors = (doc.text.anchors.add(at: l.found.range.lowerBound, bias: .after),
			             doc.text.anchors.add(at: l.found.range.upperBound, bias: .before))
		}
	}

	private func untrackAll() {
		for f in files {
			guard let doc = f.doc else { continue }
			for case let (start, end)? in f.lines.map(\.anchors) {
				doc.text.anchors.remove(start)
				doc.text.anchors.remove(end)
			}
		}
	}

	/// The lines of an edited file show their new numbers and text, after a short pause.
	private func textChanged(_ id: ObjectIdentifier) {
		guard let f = files.first(where: { $0.doc.map(ObjectIdentifier.init) == id }), refreshPending.insert(id).inserted else { return }
		DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self, weak f] in
			MainActor.assumeIsolated {
				guard let self else { return }
				self.refreshPending.remove(id)
				if let f, self.files.contains(where: { $0 === f }) { self.outline.reloadItem(f, reloadChildren: true) }
			}
		}
	}

	private func build() {
		status.textColor = .secondaryLabelColor
		status.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
		status.lineBreakMode = .byTruncatingTail
		status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
		let column = NSTableColumn(identifier: .init("usage"))
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
		outline.setAccessibilityLabel(Strings.panel.usages)
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

	/// Runs `search` and lists what it finds; nil from it means the server did not answer.
	func show(_ name: String, _ search: @escaping @MainActor () async -> [NavigationTarget]?) {
		generation += 1
		let gen = generation
		isSearching = true
		untrackAll()
		files = []
		self.name = name
		outline.reloadData()
		status.stringValue = Strings.usages.findingUsages(name: name)
		Task { [weak self] in
			let found = await search()
			guard let self, gen == generation else { return }
			isSearching = false
			guard let found else {
				status.stringValue = Strings.usages.noAnswer
				return
			}
			var byURL: [URL: FileItem] = [:]
			for target in found {
				let file = byURL[target.url] ?? {
					let f = FileItem(target.url, NavigationController.path(target.url, root: project.url))
					byURL[target.url] = f
					files.append(f)
					return f
				}()
				file.lines.append(LineItem(file, target))
			}
			files.forEach(track)
			outline.reloadData()
			outline.expandItem(nil, expandChildren: true)
			status.stringValue = found.isEmpty ? Strings.usages.noUsagesOf(name: name)
				: Strings.usages.title(name: name, summary: Strings.usages.usageCount(count: found.count) + " " + Strings.common.inFiles(count: files.count))
			NSAccessibility.post(element: status, notification: .valueChanged)
		}
	}

	// Snapshot mode.
	var statusText: String { status.stringValue }
	var rowsForSnapshot: [String] {
		(0..<outline.numberOfRows).map { row in
			switch outline.item(atRow: row) {
			case let f as FileItem: f.path
			case let l as LineItem: "    " + FindInFiles.lineText(l.target.line).string
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
		// Browsing with the arrow keys is not a jump of its own (Back returns to where it began).
		if NSApp.currentEvent?.type == .keyDown { openSelected(focusEditor: false, record: false) }
	}

	private func openSelected(focusEditor: Bool, record: Bool = true) {
		let line: LineItem
		switch outline.item(atRow: outline.selectedRow) {
		case let l as LineItem: line = l
		case let f as FileItem:
			guard let first = f.lines.first else { return }
			line = first
		default: return
		}
		guard let app = NSApp.delegate as? AppDelegate else { return }
		if record { (view.window?.delegate as? DocumentWindow)?.recordJump() }
		let url = line.file.url
		app.open(url, from: project)
		let wasTracked = line.file.doc != nil
		track(line.file)
		guard let doc = line.file.doc, let editor = doc.text.views.first(where: { $0.window?.isKeyWindow == true }) ?? doc.text.views.first else { return }
		var range = line.target.range
		// Opened earlier and edited before this list knew it: the nearest occurrence of the name.
		if !wasTracked, !name.isEmpty, doc.text.rope.string(in: range) != name {
			let near = doc.text.rope.ranges(of: Array(name.utf8), wholeWord: true)
			if let best = near.min(by: { abs($0.lowerBound - range.lowerBound) < abs($1.lowerBound - range.lowerBound) }) { range = best }
		}
		editor.reveal(range)
		if focusEditor {
			editor.window?.makeFirstResponder(editor)
		} else {
			// The panel moves with the tab in front; keep browsing usages there.
			DispatchQueue.main.async { [weak self] in
				guard let self, let window = view.window else { return }
				window.makeFirstResponder(outline)
			}
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
		let cell = outlineView.makeView(withIdentifier: id, owner: self) as? NSTableCellView ?? FindInFiles.cell(id, icon: item is FileItem)
		if let f = item as? FileItem {
			cell.imageView?.image = NSWorkspace.shared.icon(forFile: f.url.path)
			let text = NSMutableAttributedString(string: f.url.lastPathComponent, attributes: [.font: NSFont.boldSystemFont(ofSize: NSFont.smallSystemFontSize)])
			let folder = (f.path as NSString).deletingLastPathComponent
			let rest = (folder.isEmpty ? "" : "  " + folder) + "  " + String(f.lines.count)
			text.append(NSAttributedString(string: rest, attributes: [.font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize), .foregroundColor: NSColor.secondaryLabelColor]))
			cell.textField?.attributedStringValue = text
			cell.setAccessibilityLabel(f.path)
		} else if let l = item as? LineItem {
			cell.textField?.attributedStringValue = FindInFiles.lineText(l.target.line)
		}
		return cell
	}
}
