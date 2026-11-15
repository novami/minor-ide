import AppKit

/// Bar above the editor when the file changed or vanished on disk while the window has
/// unsaved changes: a message and up to two buttons (the first is the default).
@MainActor
final class DiskBanner: NSView {
	private let label = NSTextField(labelWithString: "")
	private let first = NSButton(title: "", target: nil, action: nil)
	private let second = NSButton(title: "", target: nil, action: nil)
	private var actions: [() -> Void] = []

	init() {
		super.init(frame: .zero)
		label.lineBreakMode = .byTruncatingTail
		label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
		let icon = NSImageView(image: NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: nil) ?? NSImage())
		icon.contentTintColor = .systemYellow
		for (i, b) in [first, second].enumerated() {
			b.bezelStyle = .rounded
			b.controlSize = .small
			b.tag = i
			b.target = self
			b.action = #selector(pressed(_:))
		}
		first.keyEquivalent = "\r"
		let row = NSStackView(views: [icon, label, NSView(), second, first])
		row.orientation = .horizontal
		row.spacing = 8
		row.edgeInsets = NSEdgeInsets(top: 6, left: 10, bottom: 6, right: 10)
		row.translatesAutoresizingMaskIntoConstraints = false
		let separator = NSBox()
		separator.boxType = .separator
		separator.translatesAutoresizingMaskIntoConstraints = false
		addSubview(row)
		addSubview(separator)
		NSLayoutConstraint.activate([
			row.leadingAnchor.constraint(equalTo: leadingAnchor),
			row.trailingAnchor.constraint(equalTo: trailingAnchor),
			row.topAnchor.constraint(equalTo: topAnchor),
			row.bottomAnchor.constraint(equalTo: separator.topAnchor),
			separator.leadingAnchor.constraint(equalTo: leadingAnchor),
			separator.trailingAnchor.constraint(equalTo: trailingAnchor),
			separator.bottomAnchor.constraint(equalTo: bottomAnchor),
		])
		setAccessibilityRole(.group)
		isHidden = true
	}

	@available(*, unavailable)
	required init?(coder: NSCoder) { fatalError("not supported") }

	/// Shows the message with buttons (title, action); the bar hides after a button.
	func show(_ message: String, _ buttons: [(String, () -> Void)]) {
		label.stringValue = message
		setAccessibilityLabel(message)
		actions = buttons.map(\.1)
		first.title = buttons.first?.0 ?? ""
		second.title = buttons.count > 1 ? buttons[1].0 : ""
		second.isHidden = buttons.count < 2
		isHidden = false
		NSAccessibility.post(element: self, notification: .announcementRequested,
		                     userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.high.rawValue])
	}

	@objc private func pressed(_ sender: NSButton) {
		isHidden = true
		if sender.tag < actions.count { actions[sender.tag]() }
	}
}
