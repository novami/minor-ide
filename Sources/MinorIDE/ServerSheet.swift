import AppKit
import RemoteKit
import SecretsKit

extension Notification.Name {
	/// Posted on the main thread after a saved server was added, changed or deleted.
	static let serversDidChange = Notification.Name("MinorIDE.serversDidChange")
}

/// Saving and deleting servers: the settings file without passwords, the password in the
/// Keychain (off the main thread, see `Databases`).
enum Servers {
	static let store = ServerStore()
	static let keychain = Keychain()

	static func save(_ server: RemoteServer, password: String?) async throws {
		if let password {
			try await Task.detached { try keychain.setPassword(password, server.passwordID) }.value
		}
		try store.save(server)
		NotificationCenter.default.post(name: .serversDidChange, object: nil)
	}

	static func delete(_ server: RemoteServer) async throws {
		try store.remove(id: server.id)
		NotificationCenter.default.post(name: .serversDidChange, object: nil)
		try await Task.detached { try keychain.delete(server.passwordID) }.value
	}

	static func password(_ server: RemoteServer) async -> String? {
		try? await Task.detached { try keychain.password(server.passwordID) }.value
	}
}

/// Sheet for adding or editing a saved SFTP or FTPS server. Verifying the host key and
/// connecting come in phase 6b.
@MainActor
final class ServerSheet: NSObject, NSTextFieldDelegate {
	private static let kinds: [(RemoteServer.Kind, String)] = [
		(.sftp, "SFTP"), (.ftps, L("FTPS (FTP over TLS)")),
	]

	private var server: RemoteServer
	private let isNew: Bool
	private let panel: NSPanel
	private let grid = NSGridView()
	private let kind = NSPopUpButton()
	private let name = NSTextField()
	private let host = NSTextField()
	private let port = NSTextField()
	private let user = NSTextField()
	private let authentication = NSPopUpButton()
	private let keyFile = NSTextField()
	private let password = NSSecureTextField()
	private let remotePath = NSTextField()
	private let production = NSButton(checkboxWithTitle: L("Production server"), target: nil, action: nil)
	private let saveButton: NSButton
	/// The password as loaded from the Keychain (nil while loading); an unchanged one is not written again.
	private var loadedPassword: String?
	private var authRow: NSGridRow!
	private var keyRow: NSGridRow!
	private var passwordRow: NSGridRow!

	/// Shows the sheet on `window`; `server` nil adds a new one.
	static func present(on window: NSWindow, editing server: RemoteServer? = nil) {
		let sheet = ServerSheet(server: server)
		// The completion handler keeps the sheet alive while it is shown.
		window.beginSheet(sheet.panel) { _ in _ = sheet }
	}

	private init(server: RemoteServer?) {
		isNew = server == nil
		self.server = server ?? RemoteServer()
		panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 460, height: 300), styleMask: [.titled], backing: .buffered, defer: true)
		saveButton = NSButton(title: server == nil ? L("Add") : L("Save"), target: nil, action: nil)
		super.init()
		build()
		fill()
		if isNew {
			loadedPassword = ""
		} else {
			let s = self.server
			Task {
				let saved = await Servers.password(s) ?? ""
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
		authentication.addItems(withTitles: [L("SSH Key"), L("Password")])
		for popup in [kind, authentication] {
			popup.target = self
			popup.action = #selector(changed(_:))
		}
		for field in [name, host, port, user, keyFile, password, remotePath] {
			field.delegate = self
		}
		name.placeholderString = L("Required")
		host.placeholderString = "example.com"
		port.alignment = .right
		keyFile.placeholderString = L("From SSH configuration")
		password.placeholderString = L("Stored in the Keychain")
		remotePath.placeholderString = L("Login folder")
		production.target = self
		production.action = #selector(changed(_:))

		func label(_ text: String) -> NSTextField {
			let l = NSTextField(labelWithString: text)
			l.alignment = .right
			return l
		}
		let hostRow = NSStackView(views: [host, NSTextField(labelWithString: L("Port:")), port])
		hostRow.spacing = 6
		host.setContentHuggingPriority(.defaultLow, for: .horizontal)
		port.widthAnchor.constraint(equalToConstant: 64).isActive = true
		let keyStack = NSStackView(views: [keyFile, NSButton(title: L("Choose…"), target: self, action: #selector(chooseKey(_:)))])
		keyStack.spacing = 6
		keyFile.setContentHuggingPriority(.defaultLow, for: .horizontal)
		let productionNote = NSTextField(wrappingLabelWithString: L("Shown in red; uploads ask for confirmation."))
		productionNote.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
		productionNote.textColor = .secondaryLabelColor

		grid.addRow(with: [label(L("Type:")), kind])
		grid.addRow(with: [label(L("Name:")), name])
		grid.addRow(with: [label(L("Host:")), hostRow])
		grid.addRow(with: [label(L("User:")), user])
		authRow = grid.addRow(with: [label(L("Log In With:")), authentication])
		keyRow = grid.addRow(with: [label(L("Key File:")), keyStack])
		passwordRow = grid.addRow(with: [label(L("Password:")), password])
		grid.addRow(with: [label(L("Remote Folder:")), remotePath])
		grid.addRow(with: [NSGridCell.emptyContentView, production])
		grid.addRow(with: [NSGridCell.emptyContentView, productionNote])
		grid.rowSpacing = 8
		grid.columnSpacing = 8
		grid.column(at: 0).xPlacement = .trailing
		grid.rowAlignment = .firstBaseline
		grid.column(at: 1).width = 300

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
		panel.title = isNew ? L("Add Server") : L("Edit Server")
		panel.initialFirstResponder = name
	}

	private func fill() {
		let s = server
		kind.selectItem(at: Self.kinds.firstIndex { $0.0 == s.kind } ?? 0)
		name.stringValue = s.name
		host.stringValue = s.host
		port.stringValue = s.port.map(String.init) ?? ""
		user.stringValue = s.user
		authentication.selectItem(at: s.authentication == .key ? 0 : 1)
		keyFile.stringValue = s.keyFile
		remotePath.stringValue = s.remotePath
		production.state = s.production ? .on : .off
		update()
	}

	/// The server as entered in the fields.
	private func read() -> RemoteServer {
		var s = server
		s.kind = Self.kinds[max(kind.indexOfSelectedItem, 0)].0
		s.name = name.stringValue.trimmingCharacters(in: .whitespaces)
		s.host = host.stringValue.trimmingCharacters(in: .whitespaces)
		let portText = port.stringValue.trimmingCharacters(in: .whitespaces)
		s.port = portText.isEmpty ? nil : (Int(portText) ?? -1)
		s.user = user.stringValue.trimmingCharacters(in: .whitespaces)
		s.authentication = s.kind == .ftps || authentication.indexOfSelectedItem == 1 ? .password : .key
		s.keyFile = s.authentication == .key ? keyFile.stringValue : ""
		s.remotePath = remotePath.stringValue.trimmingCharacters(in: .whitespaces)
		s.production = production.state == .on
		return s
	}

	private func update() {
		let s = read()
		authRow.isHidden = s.kind == .ftps
		keyRow.isHidden = s.usesPassword
		passwordRow.isHidden = !s.usesPassword
		port.placeholderString = String(s.kind.defaultPort)
		user.placeholderString = s.kind == .sftp ? L("From SSH configuration") : L("Required")
		saveButton.isEnabled = s.isComplete
	}

	@objc private func changed(_ sender: Any?) { update() }
	func controlTextDidChange(_ obj: Notification) { update() }

	@objc private func chooseKey(_ sender: Any?) {
		let open = NSOpenPanel()
		open.message = L("Choose the private key for the server.")
		open.showsHiddenFiles = true
		open.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh")
		open.beginSheetModal(for: panel) { [weak self] response in
			guard response == .OK, let url = open.url, let self else { return }
			MainActor.assumeIsolated {
				self.keyFile.stringValue = url.path
				self.update()
			}
		}
	}

	@objc private func cancel(_ sender: Any?) { close() }

	@objc private func save(_ sender: Any?) {
		let s = read()
		guard s.isComplete else { return }
		// Key login keeps no password; an empty field before the saved one loaded keeps it.
		let typed = password.stringValue
		let unchanged = typed == loadedPassword || (loadedPassword == nil && typed.isEmpty)
		let pass: String? = !s.usesPassword ? "" : (unchanged ? nil : typed)
		saveButton.isEnabled = false
		Task {
			do {
				try await Servers.save(s, password: pass)
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
