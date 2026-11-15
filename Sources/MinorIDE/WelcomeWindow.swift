import AppKit

/// Window › Welcome to MinorIDE (⇧⌘1), shown at launch with nothing to open: actions on the
/// left, recent projects and files on the right. Opening anything closes it.
@MainActor
final class WelcomeWindow: NSObject, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
	static let shared = WelcomeWindow()
	weak var target: AppDelegate?
	private var window: NSWindow?
	private var table: RecentTable?
	private var emptyLabel: NSTextField?
	private var recent: [URL] = []

	func show() {
		if window == nil { window = makeWindow() }
		reload()
		window?.makeKeyAndOrderFront(nil)
		if let table { window?.makeFirstResponder(table) }
	}

	func close() { window?.close() }

	private func reload(_ urls: [URL] = NSDocumentController.shared.recentDocumentURLs) {
		recent = urls.filter { FileManager.default.fileExists(atPath: $0.path) }
		table?.reloadData()
		if !recent.isEmpty { table?.selectRowIndexes([0], byExtendingSelection: false) }
		emptyLabel?.isHidden = !recent.isEmpty
	}

	private func makeWindow() -> NSWindow {
		let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 440),
		                      styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
		window.title = L("Welcome to MinorIDE")
		window.titleVisibility = .hidden
		window.titlebarAppearsTransparent = true
		window.isMovableByWindowBackground = true
		window.isReleasedWhenClosed = false
		window.delegate = self

		let content = NSView()
		let actions = makeActions()
		let list = makeList()
		for view in [actions, list] {
			view.translatesAutoresizingMaskIntoConstraints = false
			content.addSubview(view)
		}
		NSLayoutConstraint.activate([
			actions.leadingAnchor.constraint(equalTo: content.leadingAnchor),
			actions.topAnchor.constraint(equalTo: content.topAnchor),
			actions.bottomAnchor.constraint(equalTo: content.bottomAnchor),
			list.leadingAnchor.constraint(equalTo: actions.trailingAnchor),
			list.trailingAnchor.constraint(equalTo: content.trailingAnchor),
			list.topAnchor.constraint(equalTo: content.topAnchor),
			list.bottomAnchor.constraint(equalTo: content.bottomAnchor),
			list.widthAnchor.constraint(equalToConstant: 300),
		])
		window.contentView = content
		window.center()
		return window
	}

	private func makeActions() -> NSView {
		let icon = NSImageView(image: NSApp.applicationIconImage ?? NSImage())
		icon.imageScaling = .scaleProportionallyUpOrDown
		NSLayoutConstraint.activate([icon.widthAnchor.constraint(equalToConstant: 128), icon.heightAnchor.constraint(equalToConstant: 128)])
		let name = NSTextField(labelWithString: "MinorIDE")
		name.font = .systemFont(ofSize: 30, weight: .bold)
		let views: [NSView] = [icon, name]
		let stack = NSStackView(views: views)
		if let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
			let label = NSTextField(labelWithString: L("Version %@", version))
			label.textColor = .secondaryLabelColor
			stack.addArrangedSubview(label)
		}
		let buttons = NSStackView(views: [
			actionButton(L("Open Folder or File…"), "folder", #selector(AppDelegate.openDocument(_:))),
			actionButton(L("New File"), "doc.badge.plus", #selector(AppDelegate.newDocument(_:))),
		])
		buttons.orientation = .vertical
		buttons.alignment = .leading
		buttons.spacing = 4
		stack.addArrangedSubview(buttons)
		stack.orientation = .vertical
		stack.alignment = .centerX
		stack.spacing = 6
		stack.setCustomSpacing(10, after: icon)
		stack.setCustomSpacing(36, after: stack.arrangedSubviews[stack.arrangedSubviews.count - 2])

		let container = NSView()
		stack.translatesAutoresizingMaskIntoConstraints = false
		container.addSubview(stack)
		NSLayoutConstraint.activate([
			stack.centerXAnchor.constraint(equalTo: container.centerXAnchor),
			stack.centerYAnchor.constraint(equalTo: container.centerYAnchor, constant: -10),
			container.widthAnchor.constraint(equalToConstant: 460),
		])
		return container
	}

	private func actionButton(_ title: String, _ symbol: String, _ action: Selector) -> NSButton {
		let button = NSButton(title: title, target: target, action: action)
		// Symbols differ in width; a fixed box lines up the titles.
		let glyph = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
			.withSymbolConfiguration(.init(pointSize: 17, weight: .regular))
		let box = NSImage(size: NSSize(width: 26, height: 22), flipped: false) { rect in
			guard let glyph else { return false }
			glyph.draw(in: NSRect(x: (rect.width - glyph.size.width) / 2, y: (rect.height - glyph.size.height) / 2,
			                      width: glyph.size.width, height: glyph.size.height))
			return true
		}
		box.isTemplate = true
		button.image = box
		button.imagePosition = .imageLeading
		button.imageHugsTitle = true
		button.isBordered = false
		button.font = .systemFont(ofSize: 14, weight: .medium)
		button.contentTintColor = .controlAccentColor
		button.widthAnchor.constraint(greaterThanOrEqualToConstant: 240).isActive = true
		button.heightAnchor.constraint(equalToConstant: 28).isActive = true
		button.alignment = .left
		return button
	}

	private func makeList() -> NSView {
		let background = NSVisualEffectView()
		background.material = .sidebar
		background.blendingMode = .behindWindow

		let table = RecentTable()
		let column = NSTableColumn(identifier: .init("recent"))
		table.addTableColumn(column)
		table.headerView = nil
		table.style = .sourceList
		table.rowHeight = 44
		table.backgroundColor = .clear
		table.dataSource = self
		table.delegate = self
		table.target = self
		table.doubleAction = #selector(openClicked(_:))
		table.onReturn = { [weak self] in self?.openSelected() }
		table.setAccessibilityLabel(L("Recent Projects and Files"))
		let menu = NSMenu()
		menu.delegate = self
		table.menu = menu
		self.table = table

		let scroll = NSScrollView()
		scroll.documentView = table
		scroll.drawsBackground = false
		scroll.hasVerticalScroller = true
		scroll.autohidesScrollers = true
		scroll.automaticallyAdjustsContentInsets = false
		scroll.contentInsets = NSEdgeInsets(top: 34, left: 0, bottom: 10, right: 0) // below the close button

		let empty = NSTextField(labelWithString: L("No Recent Projects"))
		empty.textColor = .secondaryLabelColor
		empty.font = .systemFont(ofSize: 15)
		emptyLabel = empty

		for view in [scroll, empty] as [NSView] {
			view.translatesAutoresizingMaskIntoConstraints = false
			background.addSubview(view)
		}
		NSLayoutConstraint.activate([
			scroll.leadingAnchor.constraint(equalTo: background.leadingAnchor),
			scroll.trailingAnchor.constraint(equalTo: background.trailingAnchor),
			scroll.topAnchor.constraint(equalTo: background.topAnchor),
			scroll.bottomAnchor.constraint(equalTo: background.bottomAnchor),
			empty.centerXAnchor.constraint(equalTo: background.centerXAnchor),
			empty.centerYAnchor.constraint(equalTo: background.centerYAnchor),
		])
		return background
	}

	/// Saves the window (controls drawn by hosted layers may be missing) and prints frames.
	/// `MINORIDE_WELCOME` may list paths (separated by `:`) to show instead of the recent list.
	func snapshot(to path: String) {
		guard let window, let content = window.contentView else { return }
		let paths = ProcessInfo.processInfo.environment["MINORIDE_WELCOME", default: ""].split(separator: ":")
		if !paths.isEmpty { reload(paths.map { URL(fileURLWithPath: String($0)) }) }
		window.displayIfNeeded()
		func dump(_ view: NSView, _ depth: Int) {
			let text = (view as? NSTextField)?.stringValue ?? (view as? NSButton)?.title ?? ""
			print(String(repeating: "  ", count: depth) + "\(type(of: view)) \(NSStringFromRect(view.convert(view.bounds, to: nil))) \(text)")
			if !(view is NSButton) && !(view is NSTextField) && depth < 8 { view.subviews.forEach { dump($0, depth + 1) } }
		}
		dump(content, 0)
		print("rows", recent.count, "first responder", type(of: window.firstResponder as Any))
		if let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
			content.cacheDisplay(in: content.bounds, to: rep)
			try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
		}
	}

	// MARK: Opening

	@objc private func openClicked(_ sender: Any?) {
		guard let row = table?.clickedRow, recent.indices.contains(row) else { return }
		open(recent[row])
	}

	private func openSelected() {
		guard let row = table?.selectedRow, recent.indices.contains(row) else { return }
		open(recent[row])
	}

	private func open(_ url: URL) {
		target?.open(url) // the new window closes this one (AppDelegate.add)
	}

	@objc private func openFromMenu(_ sender: NSMenuItem) {
		if let url = sender.representedObject as? URL { open(url) }
	}

	@objc private func showInFinder(_ sender: NSMenuItem) {
		if let url = sender.representedObject as? URL { NSWorkspace.shared.activateFileViewerSelecting([url]) }
	}

	func menuNeedsUpdate(_ menu: NSMenu) {
		menu.removeAllItems()
		guard let row = table?.clickedRow, recent.indices.contains(row) else { return }
		let url = recent[row]
		menu.item(L("Open"), #selector(openFromMenu(_:)), target: self).representedObject = url
		menu.item(L("Show in Finder"), #selector(showInFinder(_:)), target: self).representedObject = url
	}

	// MARK: Table

	func numberOfRows(in tableView: NSTableView) -> Int { recent.count }

	func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
		let cell = tableView.makeView(withIdentifier: RecentCell.identifier, owner: nil) as? RecentCell ?? RecentCell()
		cell.show(recent[row])
		return cell
	}
}

/// Return or Enter opens the selected row.
final class RecentTable: NSTableView {
	var onReturn: (() -> Void)?

	override func keyDown(with event: NSEvent) {
		if event.keyCode == 36 || event.keyCode == 76 { onReturn?() } else { super.keyDown(with: event) }
	}
}

/// Icon, name and the folder it is in (home as ~).
final class RecentCell: NSTableCellView {
	static let identifier = NSUserInterfaceItemIdentifier("RecentCell")
	private let icon = NSImageView()
	private let name = NSTextField(labelWithString: "")
	private let path = NSTextField(labelWithString: "")

	init() {
		super.init(frame: .zero)
		identifier = Self.identifier
		name.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
		path.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
		path.textColor = .secondaryLabelColor
		for label in [name, path] {
			label.lineBreakMode = .byTruncatingMiddle
			label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
		}
		let text = NSStackView(views: [name, path])
		text.orientation = .vertical
		text.alignment = .leading
		text.spacing = 1
		for view in [icon, text] as [NSView] {
			view.translatesAutoresizingMaskIntoConstraints = false
			addSubview(view)
		}
		NSLayoutConstraint.activate([
			icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
			icon.centerYAnchor.constraint(equalTo: centerYAnchor),
			icon.widthAnchor.constraint(equalToConstant: 32),
			icon.heightAnchor.constraint(equalToConstant: 32),
			text.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
			text.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -4),
			text.centerYAnchor.constraint(equalTo: centerYAnchor),
		])
		imageView = icon
		textField = name
	}

	@available(*, unavailable)
	required init?(coder: NSCoder) { fatalError("not supported") }

	func show(_ url: URL) {
		icon.image = NSWorkspace.shared.icon(forFile: url.path)
		name.stringValue = url.lastPathComponent
		path.stringValue = (url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath
		setAccessibilityLabel("\(url.lastPathComponent), \(path.stringValue)")
	}
}
