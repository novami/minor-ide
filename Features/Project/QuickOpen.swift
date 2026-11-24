import AppKit

/// Open Quickly (⇧⌘O): a floating panel over the project window with a search field and the
/// best matching project files. Typing filters (fuzzy), ↑/↓ choose, Return opens, ⌥Return
/// opens in the split editor, Esc or a click elsewhere closes. `name:42` opens at line 42.
@MainActor
final class QuickOpenPanel: NSPanel, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
	private let project: Project
	private weak var owner: DocumentWindow?
	private let field = NSSearchField()
	private let table = NSTableView()
	private let scroll = NSScrollView()
	private let empty = NSTextField(labelWithString: "")
	private var results: [PathIndex.Match] = []
	private var query = ""
	private var line: Int?
	private var generation = 0
	private static let rowHeight: CGFloat = 36
	private static let maxRows = 10

	/// Navigate › Recent Files (⌃⌘E): only files opened lately, newest first.
	let recentOnly: Bool

	init(project: Project, owner: DocumentWindow, recentOnly: Bool = false) {
		self.project = project
		self.owner = owner
		self.recentOnly = recentOnly
		super.init(contentRect: NSRect(x: 0, y: 0, width: 620, height: 60),
		           styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: true)
		titleVisibility = .hidden
		titlebarAppearsTransparent = true
		isMovable = false
		hidesOnDeactivate = true
		becomesKeyOnlyIfNeeded = false
		for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] { standardWindowButton(button)?.isHidden = true }
		setAccessibilityLabel(Strings.quickOpen.openQuickly)

		let background = NSVisualEffectView()
		background.material = .menu
		background.state = .active
		contentView = background

		field.placeholderString = recentOnly ? Strings.quickOpen.recentFiles : Strings.quickOpen.openQuickly
		field.font = .systemFont(ofSize: 18)
		field.focusRingType = .none
		field.delegate = self
		field.sendsSearchStringImmediately = true
		field.setAccessibilityLabel(Strings.quickOpen.fileName)

		let column = NSTableColumn(identifier: .init("file"))
		table.addTableColumn(column)
		table.headerView = nil
		table.rowHeight = Self.rowHeight
		table.style = .plain
		table.backgroundColor = .clear
		table.intercellSpacing = .zero
		table.dataSource = self
		table.delegate = self
		table.target = self
		table.doubleAction = #selector(openSelected(_:))
		table.setAccessibilityLabel(Strings.quickOpen.matchingFiles)
		scroll.documentView = table
		scroll.drawsBackground = false
		scroll.hasVerticalScroller = true
		scroll.autohidesScrollers = true

		empty.textColor = .secondaryLabelColor
		empty.alignment = .center

		for v in [field, scroll, empty] as [NSView] {
			v.translatesAutoresizingMaskIntoConstraints = false
			background.addSubview(v)
		}
		NSLayoutConstraint.activate([
			field.topAnchor.constraint(equalTo: background.topAnchor, constant: 14),
			field.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 14),
			field.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -14),
			scroll.topAnchor.constraint(equalTo: field.bottomAnchor, constant: 8),
			scroll.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 6),
			scroll.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -6),
			scroll.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -6),
			empty.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
			empty.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
		])
		search()
	}

	/// Shows the panel near the top of the project window.
	func show(over window: NSWindow) {
		let frame = window.frame
		let width = min(620, frame.width - 40)
		setFrame(NSRect(x: frame.midX - width / 2, y: frame.maxY - 120 - self.frame.height, width: width, height: self.frame.height), display: false)
		window.addChildWindow(self, ordered: .above)
		makeKeyAndOrderFront(nil)
		makeFirstResponder(field)
	}

	override var canBecomeKey: Bool { true }

	override func resignKey() {
		super.resignKey()
		close()
	}

	override func close() {
		parent?.removeChildWindow(self)
		super.close()
	}

	override func cancelOperation(_ sender: Any?) { close() }

	// MARK: Search

	func controlTextDidChange(_ obj: Notification) { search() }

	private func search() {
		var text = field.stringValue.trimmingCharacters(in: .whitespaces)
		line = nil
		// "name:42" → line 42
		if let colon = text.lastIndex(of: ":"), let n = Int(text[text.index(after: colon)...]), n > 0 {
			line = n - 1
			text = String(text[..<colon])
		}
		generation += 1
		let gen = generation, index = project.paths, q = text
		let current = owner?.url.flatMap { index.relative($0.standardizedFileURL.path) }
		let recent = project.recentFiles.filter { $0 != current }, recentOnly = recentOnly
		index.whenReady {
			var found = index.search(q, recent: recent, limit: 200)
			if recentOnly {
				let set = Set(recent)
				found = found.filter { set.contains($0.path) }
			}
			DispatchQueue.main.async { [weak self] in
				guard let self, gen == generation else { return }
				show(found, for: q)
			}
		}
	}

	private func show(_ found: [PathIndex.Match], for q: String) {
		results = found
		query = q
		table.reloadData()
		if !found.isEmpty {
			table.selectRowIndexes([0], byExtendingSelection: false)
			table.scrollRowToVisible(0)
		}
		empty.stringValue = q.isEmpty ? Strings.quickOpen.noRecentFiles : Strings.quickOpen.noMatchingFiles
		empty.isHidden = !found.isEmpty
		let rows = CGFloat(min(max(found.count, 1), Self.maxRows))
		let height = 14 + field.fittingSize.height + 8 + rows * Self.rowHeight + 6
		var f = frame
		f.origin.y += f.height - height
		f.size.height = height
		setFrame(f, display: true)
	}

	/// Snapshot mode: types a query and lists the shown rows.
	func typeForSnapshot(_ text: String) {
		field.stringValue = text
		search()
	}

	var rowsForSnapshot: [String] { results.map(\.path) }

	// MARK: Keys

	func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
		switch selector {
		case #selector(NSResponder.moveUp(_:)): moveSelection(-1)
		case #selector(NSResponder.moveDown(_:)): moveSelection(1)
		case #selector(NSResponder.insertNewline(_:)): openSelected(nil)
		case #selector(NSResponder.cancelOperation(_:)): close()
		default: return false
		}
		return true
	}

	private func moveSelection(_ delta: Int) {
		guard !results.isEmpty else { return }
		let row = min(max(0, table.selectedRow + delta), results.count - 1)
		table.selectRowIndexes([row], byExtendingSelection: false)
		table.scrollRowToVisible(row)
	}

	@objc private func openSelected(_ sender: Any?) {
		let row = sender == nil ? table.selectedRow : table.clickedRow
		guard results.indices.contains(row), let app = NSApp.delegate as? AppDelegate else { return }
		let url = project.url.appendingPathComponent(results[row].path)
		let split = NSApp.currentEvent?.modifierFlags.contains(.option) == true ? owner : nil
		let line = line
		close()
		if split == nil { owner?.recordJump() }
		app.open(url, line: line, inSplitOf: split)
	}

	// MARK: Table

	func numberOfRows(in tableView: NSTableView) -> Int { results.count }

	func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
		let cell = tableView.makeView(withIdentifier: .init("QuickOpenCell"), owner: self) as? QuickOpenCell ?? QuickOpenCell()
		cell.identifier = .init("QuickOpenCell")
		cell.show(path: results[row].path, root: project.url, query: query)
		return cell
	}
}

/// A row: file icon, file name with the matched characters in bold, folder below it.
@MainActor
private final class QuickOpenCell: NSTableCellView {
	private let icon = NSImageView()
	private let name = NSTextField(labelWithString: "")
	private let folder = NSTextField(labelWithString: "")

	init() {
		super.init(frame: .zero)
		name.lineBreakMode = .byTruncatingMiddle
		folder.lineBreakMode = .byTruncatingMiddle
		folder.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
		folder.textColor = .secondaryLabelColor
		for v in [icon, name, folder] as [NSView] {
			v.translatesAutoresizingMaskIntoConstraints = false
			addSubview(v)
		}
		NSLayoutConstraint.activate([
			icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
			icon.centerYAnchor.constraint(equalTo: centerYAnchor),
			icon.widthAnchor.constraint(equalToConstant: 24),
			icon.heightAnchor.constraint(equalToConstant: 24),
			name.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
			name.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
			name.topAnchor.constraint(equalTo: topAnchor, constant: 2),
			folder.leadingAnchor.constraint(equalTo: name.leadingAnchor),
			folder.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
			folder.topAnchor.constraint(equalTo: name.bottomAnchor),
		])
		imageView = icon
		textField = name
	}

	required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

	func show(path: String, root: URL, query: String) {
		let url = root.appendingPathComponent(path)
		icon.image = NSWorkspace.shared.icon(forFile: url.path)
		let slash = path.lastIndex(of: "/")
		let nameStart = slash.map { path.utf8.distance(from: path.utf8.startIndex, to: $0) + 1 } ?? 0
		let fileName = slash.map { String(path[path.index(after: $0)...]) } ?? path
		let base = NSFont.systemFont(ofSize: NSFont.systemFontSize)
		let text = NSMutableAttributedString(string: fileName, attributes: [.font: base])
		let bold = NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)
		let nameBytes = Array(fileName.utf8)
		for p in PathIndex.positions(of: query, in: path) where p >= nameStart {
			// Byte offset in the name → UTF-16 range of that character.
			let prefix = String(decoding: nameBytes[0..<(p - nameStart)], as: UTF8.self)
			let start = prefix.utf16.count
			guard start < text.length else { continue }
			text.addAttribute(.font, value: bold, range: NSRange(location: start, length: 1))
		}
		name.attributedStringValue = text
		folder.stringValue = slash.map { String(path[..<$0]) } ?? ""
		setAccessibilityLabel(path)
	}
}
