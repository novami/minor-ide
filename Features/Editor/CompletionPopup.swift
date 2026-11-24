import AppKit

/// The completion list under the caret: a borderless panel that never becomes key (the editor
/// keeps the keyboard), a row per item (kind, label, detail) and the selected item's documentation.
@MainActor
final class CompletionPopup: NSObject, NSTableViewDataSource, NSTableViewDelegate {
	struct Row {
		var kind: Int
		var label: String
		var labelDetail: String?
		var detail: String?
		var deprecated: Bool

		init(_ item: CompletionItem) {
			kind = item.kind
			label = item.label
			labelDetail = item.labelDetail
			detail = item.detail
			deprecated = item.deprecated
		}
	}

	static let visibleRows = 10
	static let width: CGFloat = 460
	/// Kind badge and padding before the label: the label lines up with the text.
	static let labelInset: CGFloat = 28

	var onSelect: ((Int) -> Void)?
	var onAccept: ((Int) -> Void)?

	private let panel: NSPanel
	private let table = NSTableView()
	private let scroll = NSScrollView()
	private let separator = NSBox()
	private let docs = NSTextField(wrappingLabelWithString: "")
	private var rows: [Row] = []
	private var font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
	private var anchorRect = NSRect.zero
	private weak var parentWindow: NSWindow?

	override init() {
		panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 100),
		                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
		super.init()
		panel.isOpaque = false
		panel.backgroundColor = .clear
		panel.hasShadow = true
		panel.isReleasedWhenClosed = false
		panel.hidesOnDeactivate = true
		let background = NSVisualEffectView()
		background.material = .menu
		background.state = .active
		background.wantsLayer = true
		background.layer?.cornerRadius = 6
		background.layer?.masksToBounds = true
		panel.contentView = background

		let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("item"))
		column.width = Self.width
		column.resizingMask = .autoresizingMask
		table.addTableColumn(column)
		table.headerView = nil
		table.style = .plain
		table.backgroundColor = .clear
		table.intercellSpacing = NSSize(width: 0, height: 0)
		table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
		table.dataSource = self
		table.delegate = self
		table.target = self
		table.doubleAction = #selector(doubleClicked(_:))
		table.setAccessibilityLabel(Strings.completion.completions)
		scroll.documentView = table
		scroll.drawsBackground = false
		scroll.hasVerticalScroller = true
		scroll.autohidesScrollers = true
		separator.boxType = .separator
		docs.textColor = .secondaryLabelColor
		docs.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
		docs.maximumNumberOfLines = 8
		docs.lineBreakMode = .byTruncatingTail
		for view in [scroll, separator, docs] as [NSView] { background.addSubview(view) }
	}

	var isVisible: Bool { panel.isVisible }

	/// `rect`: screen rect of the completed word's start; the list opens below it, above when there is no room.
	func show(_ rows: [Row], selected: Int, docs text: String?, at rect: NSRect, parent: NSWindow, font: NSFont) {
		self.rows = rows
		self.font = font
		anchorRect = rect
		parentWindow = parent
		table.rowHeight = ceil(font.ascender - font.descender + font.leading) + 4
		table.reloadData()
		if panel.parent !== parent {
			panel.parent?.removeChildWindow(panel)
			parent.addChildWindow(panel, ordered: .above)
		}
		setDocs(text)
		select(selected)
		panel.orderFront(nil)
	}

	/// The word moved (scrolling): the list follows, shown again if it was hidden.
	func move(to rect: NSRect) {
		anchorRect = rect
		layout()
		guard !panel.isVisible, let parentWindow else { return }
		parentWindow.addChildWindow(panel, ordered: .above)
		panel.orderFront(nil)
	}

	func select(_ row: Int) {
		guard row < rows.count else { return }
		table.selectRowIndexes([row], byExtendingSelection: false)
		table.scrollRowToVisible(row)
	}

	func setDocs(_ text: String?) {
		docs.stringValue = text ?? ""
		docs.isHidden = text == nil
		separator.isHidden = text == nil
		layout()
	}

	func hide() {
		guard panel.isVisible else { return }
		panel.parent?.removeChildWindow(panel)
		panel.orderOut(nil)
	}

	private func layout() {
		let width = Self.width, pad: CGFloat = 8
		let listHeight = table.rowHeight * CGFloat(min(rows.count, Self.visibleRows)) + 8
		var docsHeight: CGFloat = 0
		if !docs.isHidden {
			docs.preferredMaxLayoutWidth = width - 2 * pad
			docsHeight = min(ceil(docs.sizeThatFits(NSSize(width: width - 2 * pad, height: 1e4)).height), 140) + 2 * pad + 1
		}
		let height = listHeight + docsHeight
		scroll.frame = NSRect(x: 0, y: docsHeight, width: width, height: listHeight)
		scroll.contentInsets = NSEdgeInsets(top: 4, left: 0, bottom: 4, right: 0)
		separator.frame = NSRect(x: 0, y: docsHeight - 1, width: width, height: 1)
		docs.frame = NSRect(x: pad, y: pad, width: width - 2 * pad, height: max(0, docsHeight - 2 * pad - 1))
		let screen = (panel.parent?.screen ?? NSScreen.main)?.visibleFrame ?? .infinite
		var origin = NSPoint(x: anchorRect.minX - Self.labelInset, y: anchorRect.minY - height - 2)
		if origin.y < screen.minY { origin.y = anchorRect.maxY + 2 }
		origin.x = max(screen.minX, min(origin.x, screen.maxX - width))
		panel.setFrame(NSRect(origin: origin, size: NSSize(width: width, height: height)), display: true)
	}

	@objc private func doubleClicked(_ sender: Any?) {
		if table.clickedRow >= 0 { onAccept?(table.clickedRow) }
	}

	// MARK: Table

	func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

	func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { EmphasizedRow() }

	func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
		let id = NSUserInterfaceItemIdentifier("completion")
		let cell = tableView.makeView(withIdentifier: id, owner: nil) as? CompletionCell ?? CompletionCell(identifier: id)
		cell.show(rows[row], font: font)
		return cell
	}

	func tableViewSelectionDidChange(_ notification: Notification) {
		if table.selectedRow >= 0 { onSelect?(table.selectedRow) }
	}
}

/// Selection drawn in the accent colour although the panel is never key.
private final class EmphasizedRow: NSTableRowView {
	override var isEmphasized: Bool {
		get { true }
		set {}
	}
}

private final class CompletionCell: NSTableCellView {
	private let badge = NSImageView()
	private let label = NSTextField(labelWithString: "")
	private let detail = NSTextField(labelWithString: "")

	init(identifier: NSUserInterfaceItemIdentifier) {
		super.init(frame: .zero)
		self.identifier = identifier
		label.lineBreakMode = .byTruncatingTail
		detail.lineBreakMode = .byTruncatingTail
		detail.textColor = .secondaryLabelColor
		detail.alignment = .right
		label.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
		detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
		detail.setContentHuggingPriority(.defaultLow, for: .horizontal)
		let stack = NSStackView(views: [badge, label, detail])
		stack.spacing = 6
		stack.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 10)
		stack.translatesAutoresizingMaskIntoConstraints = false
		addSubview(stack)
		NSLayoutConstraint.activate([
			stack.leadingAnchor.constraint(equalTo: leadingAnchor),
			stack.trailingAnchor.constraint(equalTo: trailingAnchor),
			stack.centerYAnchor.constraint(equalTo: centerYAnchor),
			badge.widthAnchor.constraint(equalToConstant: 14),
		])
		textField = label
	}

	required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

	func show(_ row: CompletionPopup.Row, font: NSFont) {
		let (letter, color, name) = Self.kind(row.kind)
		badge.image = NSImage(systemSymbolName: "\(letter).square.fill", accessibilityDescription: name)
		badge.contentTintColor = color
		let text = NSMutableAttributedString(string: row.label, attributes: [
			.font: font,
			.strikethroughStyle: row.deprecated ? NSUnderlineStyle.single.rawValue : 0,
		])
		if let extra = row.labelDetail {
			text.append(NSAttributedString(string: " " + extra, attributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor]))
		}
		label.attributedStringValue = text
		detail.stringValue = row.detail ?? ""
		detail.font = .systemFont(ofSize: max(10, font.pointSize - 1))
	}

	/// Badge letter, colour and spoken name of a `CompletionItemKind`.
	static func kind(_ kind: Int) -> (String, NSColor, String) {
		switch kind {
		case 2: ("m", .systemPurple, Strings.completion.method)
		case 3, 4: ("f", .systemPurple, Strings.completion.function)
		case 5, 10: ("p", .systemBlue, Strings.completion.field)
		case 6: ("v", .systemBlue, Strings.completion.variable)
		case 12, 20, 21: ("c", .systemTeal, Strings.completion.constant)
		case 7, 8, 13, 22, 25: ("t", .systemOrange, Strings.completion.type)
		case 9, 17, 19: ("n", .systemBrown, Strings.completion.package)
		case 14: ("k", .systemGray, Strings.completion.keyword)
		case 15: ("s", .systemGreen, Strings.completion.snippet)
		default: ("a", .systemGray, Strings.completion.plainText)
		}
	}
}
