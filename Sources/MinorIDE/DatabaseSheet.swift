import AppKit
import DBKit
import SecretsKit

extension Notification.Name {
	/// Posted on the main thread after a saved database was added, changed or deleted.
	static let databasesDidChange = Notification.Name("MinorIDE.databasesDidChange")
}

/// Saving and deleting connections: the settings file without passwords, the password in the
/// Keychain. Keychain calls can block (a system prompt), so they run off the main thread.
enum Databases {
	static let global = ConnectionStore()
	static let keychain = Keychain()

	static func store(_ scope: SavedScope) -> ConnectionStore {
		switch scope {
		case .global: global
		case .project(let url): ConnectionStore(project: url)
		}
	}

	/// Saves into `scope`; `old` is where the connection was, it moves out of there.
	static func save(_ connection: DatabaseConnection, password: String?, in scope: SavedScope,
	                 from old: SavedScope?) async throws {
		if let password {
			try await Task.detached { try keychain.setPassword(password, connection.passwordID) }.value
		}
		try store(scope).save(connection)
		if let old, old != scope { try store(old).remove(id: connection.id) }
		NotificationCenter.default.post(name: .databasesDidChange, object: nil)
	}

	static func delete(_ connection: DatabaseConnection, in scope: SavedScope) async throws {
		try store(scope).remove(id: connection.id)
		NotificationCenter.default.post(name: .databasesDidChange, object: nil)
		try await Task.detached { try keychain.delete(connection.passwordID) }.value
	}

	static func password(_ connection: DatabaseConnection) async -> String? {
		try? await Task.detached { try keychain.password(connection.passwordID) }.value
	}
}

/// Sheet for adding or editing a saved database connection. Testing and connecting come in phase 6.
@MainActor
final class DatabaseSheet: NSObject, NSTextFieldDelegate {
	private static let kinds: [(DatabaseConnection.Kind, String)] = [
		(.mysql, "MySQL / MariaDB"), (.postgresql, "PostgreSQL"), (.sqlite, "SQLite"),
	]

	private var connection: DatabaseConnection
	private let isNew: Bool
	private let scope: ScopePicker
	private let oldScope: SavedScope?
	private let panel: NSPanel
	private let grid: NSGridView
	private let kind = NSPopUpButton()
	private let name = NSTextField()
	private let host = NSTextField()
	private let port = NSTextField()
	private let user = NSTextField()
	private let password = NSSecureTextField()
	private let database = NSTextField()
	private let file = NSTextField()
	private let useSSH = NSButton(checkboxWithTitle: L("Connect through an SSH tunnel"), target: nil, action: nil)
	private let sshHost = NSTextField()
	private let sshUser = NSTextField()
	private let sshKey = NSTextField()
	private let production = NSButton(checkboxWithTitle: L("Production database"), target: nil, action: nil)
	private let saveButton: NSButton
	/// The password as loaded from the Keychain (nil while loading); an unchanged one is not written again.
	private var loadedPassword: String?
	private var networkRows: [NSGridRow] = []
	private var fileRows: [NSGridRow] = []
	private var sshRows: [NSGridRow] = []

	/// Shows the sheet on `window`; `connection` nil adds a new one, `scope` is where it is saved.
	static func present(on window: NSWindow, project: Project, editing connection: DatabaseConnection? = nil,
	                    in scope: SavedScope? = nil) {
		let sheet = DatabaseSheet(connection: connection, project: project, scope: scope)
		// The completion handler keeps the sheet alive while it is shown.
		window.beginSheet(sheet.panel) { _ in _ = sheet }
	}

	private init(connection: DatabaseConnection?, project: Project, scope: SavedScope?) {
		isNew = connection == nil
		self.scope = ScopePicker(project: project, current: scope)
		oldScope = scope
		self.connection = connection ?? DatabaseConnection()
		panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 460, height: 300), styleMask: [.titled], backing: .buffered, defer: true)
		saveButton = NSButton(title: connection == nil ? L("Add") : L("Save"), target: nil, action: nil)
		grid = NSGridView()
		super.init()
		build()
		fill()
		if isNew {
			loadedPassword = ""
		} else {
			let c = self.connection
			Task {
				let saved = await Databases.password(c) ?? ""
				loadedPassword = saved
				if password.stringValue.isEmpty { password.stringValue = saved }
			}
		}
	}

	private func build() {
		for (k, title) in Self.kinds {
			kind.addItem(withTitle: title)
			kind.lastItem?.representedObject = k.rawValue
		}
		kind.target = self
		kind.action = #selector(changed(_:))
		for field in [name, host, port, user, password, database, file, sshHost, sshUser, sshKey] {
			field.delegate = self
		}
		name.placeholderString = L("Required")
		host.placeholderString = "localhost"
		port.alignment = .right
		sshKey.placeholderString = L("From SSH configuration")
		password.placeholderString = L("Stored in the Keychain")
		useSSH.target = self
		useSSH.action = #selector(changed(_:))
		production.target = self
		production.action = #selector(changed(_:))

		func label(_ text: String) -> NSTextField {
			let l = NSTextField(labelWithString: text)
			l.alignment = .right
			return l
		}
		func choose(_ action: Selector) -> NSButton {
			NSButton(title: L("Choose…"), target: self, action: action)
		}
		func withButton(_ field: NSTextField, _ button: NSButton) -> NSView {
			let stack = NSStackView(views: [field, button])
			stack.spacing = 6
			field.setContentHuggingPriority(.defaultLow, for: .horizontal)
			return stack
		}
		let hostRow = NSStackView(views: [host, NSTextField(labelWithString: L("Port:")), port])
		hostRow.spacing = 6
		host.setContentHuggingPriority(.defaultLow, for: .horizontal)
		port.widthAnchor.constraint(equalToConstant: 64).isActive = true
		let productionNote = NSTextField(wrappingLabelWithString: L("Shown in red and opened read-only by default."))
		productionNote.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
		productionNote.textColor = .secondaryLabelColor

		grid.addRow(with: [label(L("Available In:")), scope.popup])
		grid.addRow(with: [label(L("Type:")), kind])
		grid.addRow(with: [label(L("Name:")), name])
		networkRows = [
			grid.addRow(with: [label(L("Host:")), hostRow]),
			grid.addRow(with: [label(L("User:")), user]),
			grid.addRow(with: [label(L("Password:")), password]),
			grid.addRow(with: [label(L("Database:")), database]),
		]
		fileRows = [grid.addRow(with: [label(L("File:")), withButton(file, choose(#selector(chooseFile(_:))))])]
		let sshRow = grid.addRow(with: [NSGridCell.emptyContentView, useSSH])
		sshRows = [
			grid.addRow(with: [label(L("SSH Host:")), sshHost]),
			grid.addRow(with: [label(L("SSH User:")), sshUser]),
			grid.addRow(with: [label(L("Key File:")), withButton(sshKey, choose(#selector(chooseKey(_:))))]),
		]
		networkRows.append(sshRow)
		networkRows += sshRows
		grid.addRow(with: [NSGridCell.emptyContentView, production])
		grid.addRow(with: [NSGridCell.emptyContentView, productionNote])
		grid.rowSpacing = 8
		grid.columnSpacing = 8
		grid.column(at: 0).xPlacement = .trailing
		grid.rowAlignment = .firstBaseline
		grid.column(at: 1).width = 300
		sshRow.topPadding = 4

		let cancel = NSButton(title: L("Cancel"), target: self, action: #selector(cancel(_:)))
		cancel.keyEquivalent = "\u{1b}"
		saveButton.target = self
		saveButton.action = #selector(save(_:))
		saveButton.keyEquivalent = "\r"
		let buttons = NSStackView(views: [cancel, saveButton])
		buttons.spacing = 12

		let content = NSView()
		for v in [grid, buttons] as [NSView] {
			v.translatesAutoresizingMaskIntoConstraints = false
			content.addSubview(v)
		}
		NSLayoutConstraint.activate([
			grid.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
			grid.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
			grid.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
			buttons.topAnchor.constraint(equalTo: grid.bottomAnchor, constant: 20),
			buttons.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
			buttons.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
		])
		panel.contentView = content
		panel.title = isNew ? L("Add Database") : L("Edit Database")
		panel.initialFirstResponder = name
	}

	private func fill() {
		let c = connection
		kind.selectItem(at: Self.kinds.firstIndex { $0.0 == c.kind } ?? 0)
		name.stringValue = c.name
		host.stringValue = c.host
		port.stringValue = c.port.map(String.init) ?? ""
		user.stringValue = c.user
		database.stringValue = c.database
		file.stringValue = c.file
		useSSH.state = c.ssh == nil ? .off : .on
		sshHost.stringValue = c.ssh?.host ?? ""
		sshUser.stringValue = c.ssh?.user ?? ""
		sshKey.stringValue = c.ssh?.keyFile ?? ""
		production.state = c.production ? .on : .off
		update()
	}

	/// The connection as entered in the fields.
	private func read() -> DatabaseConnection {
		var c = connection
		c.kind = Self.kinds[max(kind.indexOfSelectedItem, 0)].0
		c.name = name.stringValue.trimmingCharacters(in: .whitespaces)
		c.host = host.stringValue.trimmingCharacters(in: .whitespaces)
		let portText = port.stringValue.trimmingCharacters(in: .whitespaces)
		c.port = portText.isEmpty ? nil : (Int(portText) ?? -1)
		c.user = user.stringValue
		c.database = database.stringValue
		c.file = file.stringValue
		c.ssh = useSSH.state == .on && c.kind.isNetwork
			? .init(host: sshHost.stringValue.trimmingCharacters(in: .whitespaces), user: sshUser.stringValue,
			        keyFile: sshKey.stringValue)
			: nil
		c.production = production.state == .on
		return c
	}

	private func update() {
		let c = read()
		for row in networkRows { row.isHidden = !c.kind.isNetwork }
		for row in fileRows { row.isHidden = c.kind.isNetwork }
		for row in sshRows { row.isHidden = !c.kind.isNetwork || useSSH.state == .off }
		port.placeholderString = c.kind.defaultPort.map(String.init)
		saveButton.isEnabled = c.isComplete
	}

	@objc private func changed(_ sender: Any?) { update() }
	func controlTextDidChange(_ obj: Notification) { update() }

	@objc private func chooseFile(_ sender: Any?) {
		let open = NSOpenPanel()
		open.message = L("Choose the SQLite database file.")
		open.beginSheetModal(for: panel) { [weak self] response in
			guard response == .OK, let url = open.url, let self else { return }
			MainActor.assumeIsolated {
				self.file.stringValue = url.path
				if self.name.stringValue.isEmpty { self.name.stringValue = url.deletingPathExtension().lastPathComponent }
				self.update()
			}
		}
	}

	@objc private func chooseKey(_ sender: Any?) {
		let open = NSOpenPanel()
		open.message = L("Choose the private key for the SSH tunnel.")
		open.showsHiddenFiles = true
		open.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh")
		open.beginSheetModal(for: panel) { [weak self] response in
			guard response == .OK, let url = open.url, let self else { return }
			MainActor.assumeIsolated {
				self.sshKey.stringValue = url.path
				self.update()
			}
		}
	}

	@objc private func cancel(_ sender: Any?) { close() }

	@objc private func save(_ sender: Any?) {
		let c = read()
		guard c.isComplete else { return }
		// A SQLite connection keeps no password; an empty field before the saved one loaded keeps it.
		let typed = password.stringValue
		let unchanged = typed == loadedPassword || (loadedPassword == nil && typed.isEmpty)
		let pass: String? = !c.kind.isNetwork ? "" : (unchanged ? nil : typed)
		saveButton.isEnabled = false
		Task {
			do {
				try await Databases.save(c, password: pass, in: scope.scope, from: oldScope)
				close()
			} catch {
				saveButton.isEnabled = true
				NSAlert(error: error).beginSheetModal(for: panel, completionHandler: nil)
			}
		}
	}

	private func close() {
		panel.sheetParent?.endSheet(panel)
	}
}
