import AppKit
import Localization
import EditorKit
import MinorCore

/// File › Local History…: versions kept when the file was saved, each compared with the
/// editor's text; Restore puts the chosen version into the editor as one undoable step.
@MainActor
final class LocalHistoryWindow: NSObject, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {
	let window: NSWindow
	let document: FileDocument
	var onClose: (() -> Void)?
	private var versions: [LocalHistory.Version] = []
	private let table = NSTableView()
	private let diffView: NSTextView
	private let restoreButton = NSButton()
	private let emptyLabel = NSTextField(wrappingLabelWithString: Strings.localHistory.empty)

	private static let dateFormat: DateFormatter = {
		let f = DateFormatter()
		f.dateStyle = .medium
		f.timeStyle = .medium
		f.doesRelativeDateFormatting = true // Today, Yesterday
		return f
	}()

	init(document: FileDocument) {
		self.document = document
		window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 980, height: 620),
		                  styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
		let scroll = NSTextView.scrollableTextView()
		diffView = scroll.documentView as! NSTextView
		super.init()
		diffView.isEditable = false
		diffView.textContainerInset = NSSize(width: 6, height: 8)
		diffView.setAccessibilityLabel(Strings.compare.comparison)

		let column = NSTableColumn(identifier: .init("version"))
		table.addTableColumn(column)
		table.headerView = nil
		table.style = .sourceList
		table.rowHeight = 36
		table.dataSource = self
		table.delegate = self
		table.setAccessibilityLabel(Strings.localHistory.savedVersions)
		let list = NSScrollView()
		list.documentView = table
		list.hasVerticalScroller = true
		list.autohidesScrollers = true
		list.drawsBackground = false

		let split = NSSplitView()
		split.isVertical = true
		split.dividerStyle = .thin
		split.addArrangedSubview(list)
		split.addArrangedSubview(scroll)
		split.setHoldingPriority(.defaultHigh, forSubviewAt: 0)
		list.widthAnchor.constraint(greaterThanOrEqualToConstant: 200).isActive = true

		restoreButton.title = Strings.localHistory.restoreThisVersion
		restoreButton.bezelStyle = .push
		restoreButton.target = self
		restoreButton.action = #selector(restore(_:))
		emptyLabel.textColor = .secondaryLabelColor
		emptyLabel.alignment = .center

		let content = NSView()
		for view in [split, restoreButton, emptyLabel] as [NSView] {
			view.translatesAutoresizingMaskIntoConstraints = false
			content.addSubview(view)
		}
		NSLayoutConstraint.activate([
			split.leadingAnchor.constraint(equalTo: content.leadingAnchor),
			split.trailingAnchor.constraint(equalTo: content.trailingAnchor),
			split.topAnchor.constraint(equalTo: content.topAnchor),
			restoreButton.topAnchor.constraint(equalTo: split.bottomAnchor, constant: 12),
			restoreButton.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
			restoreButton.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
			emptyLabel.centerXAnchor.constraint(equalTo: content.centerXAnchor),
			emptyLabel.centerYAnchor.constraint(equalTo: split.centerYAnchor),
			emptyLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 420),
		])
		window.contentView = content
		split.setPosition(240, ofDividerAt: 0)
		window.title = document.url?.lastPathComponent ?? ""
		window.subtitle = Strings.menu.localHistory
		window.isReleasedWhenClosed = false
		window.delegate = self
		window.center()
		reload()
		window.makeKeyAndOrderFront(nil)
		window.makeFirstResponder(table)
	}

	private func reload() {
		versions = document.versions
		table.reloadData()
		let empty = versions.isEmpty
		emptyLabel.isHidden = !empty
		table.enclosingScrollView?.superview?.isHidden = empty // the split view
		if !empty { table.selectRowIndexes([0], byExtendingSelection: false) }
		showSelected()
	}

	private var selected: LocalHistory.Version? {
		versions.indices.contains(table.selectedRow) ? versions[table.selectedRow] : nil
	}

	private func showSelected() {
		restoreButton.isEnabled = selected != nil
		guard let version = selected, let old = document.text(of: version) else {
			diffView.string = ""
			return
		}
		let name = document.url?.lastPathComponent ?? ""
		diffView.textStorage?.setAttributedString(CompareWindow.diff(
			old: old, new: document.text.rope.string,
			oldLabel: "\(name) (\(Self.dateFormat.string(from: version.date)))", newLabel: Strings.common.inEditor(name: name)))
		diffView.scrollToBeginningOfDocument(nil)
	}

	@objc private func restore(_ sender: Any?) {
		guard let version = selected else { return }
		document.restore(version)
		showSelected() // now identical to the editor
	}

	func windowWillClose(_ notification: Notification) { onClose?() }

	// MARK: Table

	func numberOfRows(in tableView: NSTableView) -> Int { versions.count }

	func tableViewSelectionDidChange(_ notification: Notification) { showSelected() }

	func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
		let version = versions[row]
		let date = NSTextField(labelWithString: Self.dateFormat.string(from: version.date))
		let size = NSTextField(labelWithString: ByteCountFormatter.string(fromByteCount: Int64(version.size), countStyle: .file))
		size.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
		size.textColor = .secondaryLabelColor
		let stack = NSStackView(views: [date, size])
		stack.orientation = .vertical
		stack.alignment = .leading
		stack.spacing = 1
		stack.edgeInsets = NSEdgeInsets(top: 0, left: 6, bottom: 0, right: 6)
		let cell = NSTableCellView()
		stack.translatesAutoresizingMaskIntoConstraints = false
		cell.addSubview(stack)
		NSLayoutConstraint.activate([
			stack.leadingAnchor.constraint(equalTo: cell.leadingAnchor),
			stack.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor),
			stack.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
		])
		cell.textField = date
		return cell
	}
}
