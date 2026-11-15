import AppKit

/// A side or bottom panel with sections switched by a segmented control. Sections without
/// content show an empty state saying what belongs there (HIG).
@MainActor
final class PanelView: NSView {
	struct Section {
		let title: String
		let symbol: String
		let emptyTitle: String
		let emptyText: String
	}

	let sections: [Section]
	private let picker: NSSegmentedControl
	private let body = NSView()
	private let defaultsKey: String

	init(sections: [Section], label: String, defaultsKey: String) {
		self.sections = sections
		self.defaultsKey = defaultsKey
		picker = NSSegmentedControl(labels: sections.map(\.title), trackingMode: .selectOne, target: nil, action: nil)
		super.init(frame: .zero)
		for (i, s) in sections.enumerated() {
			picker.setImage(NSImage(systemSymbolName: s.symbol, accessibilityDescription: nil), forSegment: i)
			picker.setImageScaling(.scaleProportionallyDown, forSegment: i)
		}
		picker.segmentStyle = .automatic
		picker.controlSize = .small
		picker.target = self
		picker.action = #selector(picked(_:))
		picker.setAccessibilityLabel(label)
		let separator = NSBox()
		separator.boxType = .separator
		for v in [picker, separator, body] as [NSView] {
			v.translatesAutoresizingMaskIntoConstraints = false
			addSubview(v)
		}
		NSLayoutConstraint.activate([
			picker.topAnchor.constraint(equalTo: topAnchor, constant: 6),
			picker.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 8),
			picker.centerXAnchor.constraint(equalTo: centerXAnchor),
			separator.topAnchor.constraint(equalTo: picker.bottomAnchor, constant: 6),
			separator.leadingAnchor.constraint(equalTo: leadingAnchor),
			separator.trailingAnchor.constraint(equalTo: trailingAnchor),
			body.topAnchor.constraint(equalTo: separator.bottomAnchor),
			body.leadingAnchor.constraint(equalTo: leadingAnchor),
			body.trailingAnchor.constraint(equalTo: trailingAnchor),
			body.bottomAnchor.constraint(equalTo: bottomAnchor),
		])
		setAccessibilityRole(.group)
		setAccessibilityLabel(label)
		let saved = UserDefaults.standard.integer(forKey: defaultsKey)
		select(sections.indices.contains(saved) ? saved : 0)
	}

	@available(*, unavailable)
	required init?(coder: NSCoder) { fatalError("not supported") }

	var selected: Int { picker.selectedSegment }

	func select(_ index: Int) {
		picker.selectedSegment = index
		body.subviews.forEach { $0.removeFromSuperview() }
		let empty = Self.emptyState(sections[index])
		empty.translatesAutoresizingMaskIntoConstraints = false
		body.addSubview(empty)
		NSLayoutConstraint.activate([
			empty.centerXAnchor.constraint(equalTo: body.centerXAnchor),
			empty.centerYAnchor.constraint(equalTo: body.centerYAnchor),
			empty.leadingAnchor.constraint(equalTo: body.leadingAnchor, constant: 16),
		])
		UserDefaults.standard.set(index, forKey: defaultsKey)
	}

	@objc private func picked(_ sender: NSSegmentedControl) { select(sender.selectedSegment) }

	private static func emptyState(_ s: Section) -> NSView {
		let title = NSTextField(labelWithString: s.emptyTitle)
		title.font = .systemFont(ofSize: NSFont.systemFontSize + 2, weight: .semibold)
		title.textColor = .secondaryLabelColor
		let text = NSTextField(wrappingLabelWithString: s.emptyText)
		text.textColor = .secondaryLabelColor
		text.alignment = .center
		let stack = NSStackView(views: [title, text])
		stack.orientation = .vertical
		stack.alignment = .centerX
		stack.spacing = 4
		return stack
	}
}

extension PanelView {
	/// Right panel: database and server browsers (phases 6 and 6b fill them).
	static func inspector() -> PanelView {
		PanelView(sections: [
			Section(title: L("Database"), symbol: "cylinder.split.1x2",
			        emptyTitle: L("No Databases"),
			        emptyText: L("Connections to MySQL, MariaDB, PostgreSQL and SQLite databases will appear here.")),
			Section(title: L("Server"), symbol: "server.rack",
			        emptyTitle: L("No Servers"),
			        emptyText: L("Files on servers connected over SFTP or FTPS will appear here.")),
		], label: L("Inspector"), defaultsKey: "InspectorSection")
	}

	/// Bottom panel: terminal (phase 2b).
	static func bottom() -> PanelView {
		PanelView(sections: [
			Section(title: L("Terminal"), symbol: "terminal",
			        emptyTitle: L("No Terminal"),
			        emptyText: L("A terminal in the project folder will appear here.")),
		], label: L("Bottom Panel"), defaultsKey: "BottomPanelSection")
	}
}
