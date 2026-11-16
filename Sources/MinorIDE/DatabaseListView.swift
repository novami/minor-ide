import AppKit
import DBKit

/// Saved database connections in the right panel: add, edit and delete them.
/// Connections are shared by all windows (stored outside projects).
@MainActor
final class DatabaseListView: NSView, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
	private var connections: [DatabaseConnection] = []
	private let table = NSTableView()
	private let scroll = NSScrollView()
	private let bar = NSStackView()
	private let removeButton: NSButton
	private var empty: NSView?

	init() {
		removeButton = NSButton(image: NSImage(named: NSImage.removeTemplateName)!, target: nil, action: nil)
		super.init(frame: .zero)
		let column = NSTableColumn(identifier: .init("db"))
		table.addTableColumn(column)
		table.headerView = nil
		table.style = .inset
		table.rowHeight = 36
		table.dataSource = self
		table.delegate = self
		table.target = self
		table.doubleAction = #selector(edit(_:))
		table.setAccessibilityLabel(L("Databases"))
		let menu = NSMenu()
		menu.delegate = self
		table.menu = menu
		scroll.documentView = table
		scroll.hasVerticalScroller = true
		scroll.autohidesScrollers = true
		scroll.drawsBackground = false

		let add = NSButton(image: NSImage(named: NSImage.addTemplateName)!, target: self, action: #selector(add(_:)))
		add.toolTip = L("Add Database…")
		removeButton.target = self
		removeButton.action = #selector(delete(_:))
		removeButton.toolTip = L("Delete Database…")
		for b in [add, removeButton] {
			b.bezelStyle = .smallSquare
			b.isBordered = false
			b.widthAnchor.constraint(equalToConstant: 24).isActive = true
		}
		bar.setViews([add, removeButton], in: .leading)
		bar.spacing = 0
		bar.edgeInsets = NSEdgeInsets(top: 2, left: 6, bottom: 4, right: 6)

		for v in [scroll, bar] as [NSView] {
			v.translatesAutoresizingMaskIntoConstraints = false
			addSubview(v)
		}
		NSLayoutConstraint.activate([
			scroll.topAnchor.constraint(equalTo: topAnchor),
			scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
			scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
			bar.topAnchor.constraint(equalTo: scroll.bottomAnchor),
			bar.leadingAnchor.constraint(equalTo: leadingAnchor),
			bar.trailingAnchor.constraint(equalTo: trailingAnchor),
			bar.bottomAnchor.constraint(equalTo: bottomAnchor),
		])
		NotificationCenter.default.addObserver(self, selector: #selector(reload), name: .databasesDidChange, object: nil)
		reload()
	}

	@available(*, unavailable)
	required init?(coder: NSCoder) { fatalError("not supported") }

	@objc private func reload() {
		let selected = clicked?.id
		connections = Databases.store.load()
		table.reloadData()
		if let selected, let row = connections.firstIndex(where: { $0.id == selected }) {
			table.selectRowIndexes([row], byExtendingSelection: false)
		}
		removeButton.isEnabled = table.selectedRow >= 0
		scroll.isHidden = connections.isEmpty
		bar.isHidden = connections.isEmpty
		empty?.removeFromSuperview()
		empty = nil
		guard connections.isEmpty else { return }
		let button = NSButton(title: L("Add Database…"), target: self, action: #selector(add(_:)))
		let state = PanelView.emptyState(title: L("No Databases"),
		                                 text: L("Connections to MySQL, MariaDB, PostgreSQL and SQLite databases will appear here."),
		                                 button: button)
		state.translatesAutoresizingMaskIntoConstraints = false
		addSubview(state)
		NSLayoutConstraint.activate([
			state.centerXAnchor.constraint(equalTo: centerXAnchor),
			state.centerYAnchor.constraint(equalTo: centerYAnchor),
			state.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
		])
		empty = state
	}

	/// The right-clicked row, else the selected one.
	private var clicked: DatabaseConnection? {
		let row = table.clickedRow >= 0 ? table.clickedRow : table.selectedRow
		return connections.indices.contains(row) ? connections[row] : nil
	}

	@objc private func add(_ sender: Any?) {
		guard let window else { return }
		DatabaseSheet.present(on: window)
	}

	@objc private func edit(_ sender: Any?) {
		guard let window, let c = clicked else { return }
		DatabaseSheet.present(on: window, editing: c)
	}

	@objc private func delete(_ sender: Any?) {
		guard let window, let c = clicked else { return }
		let alert = NSAlert()
		alert.messageText = L("Delete “%@”?", c.name)
		alert.informativeText = L("The connection and its password in the Keychain will be deleted. The database itself is not changed.")
		alert.addButton(withTitle: L("Delete")).hasDestructiveAction = true
		alert.addButton(withTitle: L("Cancel"))
		alert.beginSheetModal(for: window) { response in
			guard response == .alertFirstButtonReturn else { return }
			Task { @MainActor in
				do {
					try await Databases.delete(c)
				} catch {
					NSAlert(error: error).beginSheetModal(for: window, completionHandler: nil)
				}
			}
		}
	}

	// MARK: Menu

	func menuNeedsUpdate(_ menu: NSMenu) {
		menu.removeAllItems()
		if clicked != nil {
			menu.addItem(withTitle: L("Edit…"), action: #selector(edit(_:)), keyEquivalent: "").target = self
			menu.addItem(withTitle: L("Delete…"), action: #selector(delete(_:)), keyEquivalent: "").target = self
			menu.addItem(.separator())
		}
		menu.addItem(withTitle: L("Add Database…"), action: #selector(add(_:)), keyEquivalent: "").target = self
	}

	// MARK: Table

	func numberOfRows(in tableView: NSTableView) -> Int { connections.count }

	func tableViewSelectionDidChange(_ notification: Notification) {
		removeButton.isEnabled = table.selectedRow >= 0
	}

	func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
		let c = connections[row]
		let icon = NSImageView(image: NSImage(systemSymbolName: c.kind.isNetwork ? "cylinder.split.1x2" : "doc",
		                                      accessibilityDescription: nil)!)
		icon.contentTintColor = c.production ? .systemRed : .secondaryLabelColor
		let name = NSTextField(labelWithString: c.name)
		name.lineBreakMode = .byTruncatingTail
		var detail = c.summary
		if c.production { detail = L("Production") + " · " + detail }
		let summary = NSTextField(labelWithString: detail)
		summary.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
		summary.textColor = c.production ? .systemRed : .secondaryLabelColor
		summary.lineBreakMode = .byTruncatingMiddle
		let text = NSStackView(views: [name, summary])
		text.orientation = .vertical
		text.alignment = .leading
		text.spacing = 0
		let cell = NSTableCellView()
		cell.textField = name
		cell.imageView = icon
		let row = NSStackView(views: [icon, text])
		row.spacing = 6
		row.translatesAutoresizingMaskIntoConstraints = false
		cell.addSubview(row)
		NSLayoutConstraint.activate([
			row.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
			row.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor),
			row.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
			icon.widthAnchor.constraint(equalToConstant: 18),
		])
		text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
		cell.setAccessibilityLabel(c.name + ", " + detail)
		return cell
	}
}
