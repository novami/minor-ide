import AppKit
import DBKit
import RemoteKit

/// Where a saved item lives: for all projects, or in the project's `.minoride/local.json`.
enum SavedScope: Equatable, Sendable {
	case global
	case project(URL)
}

/// The “Available In” pop-up of the database and server sheets. The project's settings are
/// not read in Restricted Mode, so the project choice needs a trusted project.
@MainActor
final class ScopePicker {
	let popup = NSPopUpButton()
	private let project: Project

	/// `current` nil (a new item) picks the project when it is trusted.
	init(project: Project, current: SavedScope?) {
		self.project = project
		popup.autoenablesItems = false
		popup.addItem(withTitle: L("All Projects"))
		popup.addItem(withTitle: L("Only “%@”", project.name))
		if !project.isTrusted {
			popup.lastItem?.isEnabled = false
			popup.lastItem?.toolTip = L("Trust the project to save settings in it.")
		}
		let inProject = current.map { $0 != .global } ?? project.isTrusted
		popup.selectItem(at: inProject ? 1 : 0)
	}

	var scope: SavedScope {
		popup.indexOfSelectedItem == 1 && project.isTrusted ? .project(project.url) : .global
	}
}

/// One row of a `SavedListView`.
struct SavedRow {
	let id: UUID
	let name: String
	let detail: String
	let symbol: String
	let production: Bool
	let scope: SavedScope
}

/// What a `SavedListView` lists and how it adds, edits and deletes items.
struct SavedList {
	let load: @MainActor (Project) -> [SavedRow]
	let didChange: Notification.Name
	let add: @MainActor (NSWindow, Project) -> Void
	let edit: @MainActor (SavedRow, NSWindow, Project) -> Void
	let delete: @MainActor (SavedRow) async throws -> Void
	let label: String
	let addTitle: String
	let deleteTitle: String
	let deleteText: String
	let emptyTitle: String
	let emptyText: String

	/// The project's own items first (only in a trusted project), then those for all projects.
	@MainActor static func scopes(_ project: Project) -> [SavedScope] {
		project.isTrusted ? [.project(project.url), .global] : [.global]
	}
}

/// Saved items (databases, servers) in the right panel: add, edit and delete them.
/// Items are shared by all windows (stored outside projects).
@MainActor
final class SavedListView: NSView, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
	private let list: SavedList
	private let project: Project
	private var rows: [SavedRow] = []
	private let table = NSTableView()
	private let scroll = NSScrollView()
	private let bar = NSStackView()
	private let removeButton: NSButton
	private var empty: NSView?

	init(_ list: SavedList, project: Project) {
		self.list = list
		self.project = project
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
		table.setAccessibilityLabel(list.label)
		let menu = NSMenu()
		menu.delegate = self
		table.menu = menu
		scroll.documentView = table
		scroll.hasVerticalScroller = true
		scroll.autohidesScrollers = true
		scroll.drawsBackground = false

		let add = NSButton(image: NSImage(named: NSImage.addTemplateName)!, target: self, action: #selector(add(_:)))
		add.toolTip = list.addTitle
		removeButton.target = self
		removeButton.action = #selector(delete(_:))
		removeButton.toolTip = list.deleteTitle
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
		NotificationCenter.default.addObserver(self, selector: #selector(reload), name: list.didChange, object: nil)
		project.onTrustChange.append { [weak self] in self?.reload() }
		reload()
	}

	@available(*, unavailable)
	required init?(coder: NSCoder) { fatalError("not supported") }

	@objc private func reload() {
		let selected = clicked?.id
		rows = list.load(project)
		table.reloadData()
		if let selected, let row = rows.firstIndex(where: { $0.id == selected }) {
			table.selectRowIndexes([row], byExtendingSelection: false)
		}
		removeButton.isEnabled = table.selectedRow >= 0
		scroll.isHidden = rows.isEmpty
		bar.isHidden = rows.isEmpty
		empty?.removeFromSuperview()
		empty = nil
		guard rows.isEmpty else { return }
		let button = NSButton(title: list.addTitle, target: self, action: #selector(add(_:)))
		let state = PanelView.emptyState(title: list.emptyTitle, text: list.emptyText, button: button)
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
	private var clicked: SavedRow? {
		let row = table.clickedRow >= 0 ? table.clickedRow : table.selectedRow
		return rows.indices.contains(row) ? rows[row] : nil
	}

	@objc private func add(_ sender: Any?) {
		guard let window else { return }
		list.add(window, project)
	}

	@objc private func edit(_ sender: Any?) {
		guard let window, let c = clicked else { return }
		list.edit(c, window, project)
	}

	@objc private func delete(_ sender: Any?) {
		guard let window, let c = clicked else { return }
		let alert = NSAlert()
		alert.messageText = L("Delete “%@”?", c.name)
		alert.informativeText = list.deleteText
		alert.addButton(withTitle: L("Delete")).hasDestructiveAction = true
		alert.addButton(withTitle: L("Cancel"))
		let list = list
		alert.beginSheetModal(for: window) { response in
			guard response == .alertFirstButtonReturn else { return }
			Task { @MainActor in
				do {
					try await list.delete(c)
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
		menu.addItem(withTitle: list.addTitle, action: #selector(add(_:)), keyEquivalent: "").target = self
	}

	// MARK: Table

	func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

	func tableViewSelectionDidChange(_ notification: Notification) {
		removeButton.isEnabled = table.selectedRow >= 0
	}

	func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
		let c = rows[row]
		let icon = NSImageView(image: NSImage(systemSymbolName: c.symbol, accessibilityDescription: nil)!)
		icon.contentTintColor = c.production ? .systemRed : .secondaryLabelColor
		let name = NSTextField(labelWithString: c.name)
		name.lineBreakMode = .byTruncatingTail
		var detail = c.detail
		if c.scope != .global { detail = L("This project") + " · " + detail }
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

extension SavedList {
	@MainActor static let databases = SavedList(
		load: { project in
			scopes(project).flatMap { scope in
				Databases.store(scope).load().map {
					SavedRow(id: $0.id, name: $0.name, detail: $0.summary,
					         symbol: $0.kind.isNetwork ? "cylinder.split.1x2" : "doc", production: $0.production, scope: scope)
				}
			}
		},
		didChange: .databasesDidChange,
		add: { DatabaseSheet.present(on: $0, project: $1) },
		edit: { row, window, project in
			if let c = Databases.store(row.scope).load().first(where: { $0.id == row.id }) {
				DatabaseSheet.present(on: window, project: project, editing: c, in: row.scope)
			}
		},
		delete: { row in
			if let c = Databases.store(row.scope).load().first(where: { $0.id == row.id }) {
				try await Databases.delete(c, in: row.scope)
			}
		},
		label: L("Databases"),
		addTitle: L("Add Database…"),
		deleteTitle: L("Delete Database…"),
		deleteText: L("The connection and its password in the Keychain will be deleted. The database itself is not changed."),
		emptyTitle: L("No Databases"),
		emptyText: L("Connections to MySQL, MariaDB, PostgreSQL and SQLite databases will appear here."))

	@MainActor static let servers = SavedList(
		load: { project in
			scopes(project).flatMap { scope in
				Servers.store(scope).load().map {
					SavedRow(id: $0.id, name: $0.name, detail: $0.summary, symbol: "server.rack",
					         production: $0.production, scope: scope)
				}
			}
		},
		didChange: .serversDidChange,
		add: { ServerSheet.present(on: $0, project: $1) },
		edit: { row, window, project in
			if let s = Servers.store(row.scope).load().first(where: { $0.id == row.id }) {
				ServerSheet.present(on: window, project: project, editing: s, in: row.scope)
			}
		},
		delete: { row in
			if let s = Servers.store(row.scope).load().first(where: { $0.id == row.id }) {
				try await Servers.delete(s, in: row.scope)
			}
		},
		label: L("Servers"),
		addTitle: L("Add Server…"),
		deleteTitle: L("Delete Server…"),
		deleteText: L("The server and its password in the Keychain will be deleted. Files on the server are not changed."),
		emptyTitle: L("No Servers"),
		emptyText: L("Files on servers connected over SFTP or FTPS will appear here."))
}
