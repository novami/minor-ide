import AppKit

/// Bar above the editor when the file changed or vanished on disk while the window has
/// unsaved changes: a message and buttons (the first is the default).
@MainActor
final class DiskBanner: NSView {
	private let label = NSTextField(labelWithString: "")
	private var row: NSStackView!
	private var buttons: [NSButton] = []
	private var actions: [() -> Void] = []

	init() {
		super.init(frame: .zero)
		label.lineBreakMode = .byTruncatingTail
		label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
		let icon = NSImageView(image: NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: nil) ?? NSImage())
		icon.contentTintColor = .systemYellow
		row = NSStackView(views: [icon, label, NSView()])
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

	/// Shows the message with buttons (title, action, hides the bar); the first is the default.
	func show(_ message: String, _ choices: [(String, () -> Void, Bool)]) {
		label.stringValue = message
		setAccessibilityLabel(message)
		buttons.forEach { $0.removeFromSuperview() }
		actions = choices.map(\.1)
		hides = choices.map(\.2)
		buttons = choices.enumerated().map { i, choice in
			let b = NSButton(title: choice.0, target: self, action: #selector(pressed(_:)))
			b.bezelStyle = .rounded
			b.controlSize = .small
			b.tag = i
			if i == 0 { b.keyEquivalent = "\r" }
			return b
		}
		for b in buttons.reversed() { row.addArrangedSubview(b) }
		isHidden = false
		NSAccessibility.post(element: self, notification: .announcementRequested,
		                     userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.high.rawValue])
	}

	private var hides: [Bool] = []

	@objc private func pressed(_ sender: NSButton) {
		if sender.tag < hides.count, hides[sender.tag] { isHidden = true }
		if sender.tag < actions.count { actions[sender.tag]() }
	}
}
