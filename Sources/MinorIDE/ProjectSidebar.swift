import AppKit
import MinorCore

/// The project's files as a source list. A click on a file opens it; folders load lazily.
@MainActor
final class ProjectSidebar: NSScrollView, NSOutlineViewDataSource, NSOutlineViewDelegate {
	let project: Project
	let outline = NSOutlineView()
	/// Opens a file (the window puts it in a tab).
	var onOpen: ((URL) -> Void)?
	/// A file or folder was renamed (open windows follow it).
	var onMoved: ((URL, URL) -> Void)?
	private var restoring = false

	init(project: Project) {
		self.project = project
		super.init(frame: .zero)
		let column = NSTableColumn(identifier: .init("name"))
		column.isEditable = false
		outline.addTableColumn(column)
		outline.outlineTableColumn = column
		outline.headerView = nil
		outline.style = .sourceList
		outline.rowSizeStyle = .default
		outline.dataSource = self
		outline.delegate = self
		outline.target = self
		outline.action = #selector(clicked(_:))
		outline.autosaveExpandedItems = false
		outline.setAccessibilityLabel(L("Project Files"))
		documentView = outline
		hasVerticalScroller = true
		drawsBackground = false
		project.onChange.append { [weak self] folder in self?.reload(folder) }
		installMenu()
		restoreExpansion()
	}

	@available(*, unavailable)
	required init?(coder: NSCoder) { fatalError("not supported") }

	/// Expands the folders other tabs had open.
	func restoreExpansion() {
		restoring = true
		defer { restoring = false }
		func expand(_ node: FileNode) {
			for child in node.children where child.isDirectory && project.expanded.contains(child.url) {
				outline.expandItem(child)
				expand(child)
			}
		}
		outline.reloadData()
		expand(project.root)
	}

	private func reload(_ folder: FileNode) {
		outline.reloadItem(folder === project.root ? nil : folder, reloadChildren: true)
	}

	/// Selects a file in the tree, expanding its folders.
	func reveal(_ url: URL) {
		guard let node = project.root.node(for: url) else { return }
		var chain: [FileNode] = []
		var p = node.parent
		while let folder = p, folder !== project.root {
			chain.insert(folder, at: 0)
			p = folder.parent
		}
		for folder in chain { outline.expandItem(folder) }
		let row = outline.row(forItem: node)
		guard row >= 0 else { return }
		outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
		outline.scrollRowToVisible(row)
	}

	@objc private func clicked(_ sender: Any?) {
		guard let node = outline.item(atRow: outline.clickedRow) as? FileNode, !node.isDirectory else { return }
		onOpen?(node.url)
	}

	// Return opens the selected file too.
	override func keyDown(with event: NSEvent) {
		if event.keyCode == 36, let node = outline.item(atRow: outline.selectedRow) as? FileNode, !node.isDirectory {
			onOpen?(node.url)
		} else {
			super.keyDown(with: event)
		}
	}

	// MARK: Data source

	func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
		((item as? FileNode) ?? project.root).children.count
	}

	func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
		((item as? FileNode) ?? project.root).children[index]
	}

	func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
		(item as? FileNode)?.isDirectory ?? false
	}

	func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
		guard let node = item as? FileNode else { return nil }
		let id = NSUserInterfaceItemIdentifier("cell")
		let cell = outlineView.makeView(withIdentifier: id, owner: self) as? NSTableCellView ?? {
			let c = NSTableCellView()
			c.identifier = id
			let image = NSImageView()
			let text = NSTextField(labelWithString: "")
			text.lineBreakMode = .byTruncatingMiddle
			for v in [image, text] as [NSView] {
				v.translatesAutoresizingMaskIntoConstraints = false
				c.addSubview(v)
			}
			c.imageView = image
			c.textField = text
			NSLayoutConstraint.activate([
				image.leadingAnchor.constraint(equalTo: c.leadingAnchor),
				image.centerYAnchor.constraint(equalTo: c.centerYAnchor),
				image.widthAnchor.constraint(equalToConstant: 16),
				image.heightAnchor.constraint(equalToConstant: 16),
				text.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 5),
				text.trailingAnchor.constraint(equalTo: c.trailingAnchor),
				text.centerYAnchor.constraint(equalTo: c.centerYAnchor),
			])
			return c
		}()
		cell.textField?.stringValue = node.name
		cell.imageView?.image = NSImage(systemSymbolName: node.isDirectory ? "folder" : "doc", accessibilityDescription: nil)
		cell.imageView?.contentTintColor = node.isDirectory ? .controlAccentColor : .secondaryLabelColor
		return cell
	}

	func outlineViewItemDidExpand(_ notification: Notification) {
		if !restoring, let node = notification.userInfo?["NSObject"] as? FileNode { project.expanded.insert(node.url) }
	}

	func outlineViewItemDidCollapse(_ notification: Notification) {
		if let node = notification.userInfo?["NSObject"] as? FileNode { project.expanded.remove(node.url) }
	}
}
