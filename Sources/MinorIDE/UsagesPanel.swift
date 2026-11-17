import AppKit
import EditorKit
import MinorCore

/// Find Usages (⌥F7): a section of the bottom panel shared by the project's tabs, with the
/// usages from the language server by file. Selecting a line shows it in the editor, Return
/// or a double click also moves the focus there.
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
		init(_ url: URL, _ path: String) { self.url = url; self.path = path }
	}

	private final class LineItem {
		unowned let file: FileItem
		let target: NavigationTarget
		init(_ file: FileItem, _ target: NavigationTarget) { self.file = file; self.target = target }
	}

	private var files: [FileItem] = []
	private var generation = 0
	private(set) var isSearching = false

	init(project: Project) {
		self.project = project
		super.init()
		build()
		status.stringValue = L("Usages of a symbol appear here. Use Navigate › Find Usages in an editor.")
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
		outline.setAccessibilityLabel(L("Usages"))
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
		files = []
		outline.reloadData()
		status.stringValue = L("Finding usages of “%@”…", name)
		Task { [weak self] in
			let found = await search()
			guard let self, gen == generation else { return }
			isSearching = false
			guard let found else {
				status.stringValue = L("The language server did not answer.")
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
			outline.reloadData()
			outline.expandItem(nil, expandChildren: true)
			status.stringValue = found.isEmpty ? L("No usages of “%@”.", name)
				: L("Usages of “%@”: %@", name, LP("%d usages", one: "%d usage", found.count) + " " + LP("in %d files", one: "in %d file", files.count))
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
		if NSApp.currentEvent?.type == .keyDown { openSelected(focusEditor: false) }
	}

	private func openSelected(focusEditor: Bool) {
		let target: NavigationTarget
		switch outline.item(atRow: outline.selectedRow) {
		case let l as LineItem: target = l.target
		case let f as FileItem:
			guard let first = f.lines.first else { return }
			target = first.target
		default: return
		}
		guard let app = NSApp.delegate as? AppDelegate else { return }
		app.open(target.url, range: target.range)
		if !focusEditor {
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
