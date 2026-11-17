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
	/// Views of sections that have content (the rest show their empty state).
	private var contents: [Int: NSView] = [:]

	/// `leading` puts the section picker at the leading edge instead of the middle. `hide` is
	/// sent up the responder chain by the Hide button at the trailing edge of the header.
	init(sections: [Section], label: String, defaultsKey: String, leading: Bool = false,
	     hide: (action: Selector, symbol: String, title: String)) {
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
		let hideButton = NSButton(image: NSImage(systemSymbolName: hide.symbol, accessibilityDescription: hide.title)!,
		                          target: nil, action: hide.action)
		hideButton.isBordered = false
		hideButton.controlSize = .small
		hideButton.contentTintColor = .secondaryLabelColor
		hideButton.toolTip = hide.title
		let separator = NSBox()
		separator.boxType = .separator
		for v in [picker, hideButton, separator, body] as [NSView] {
			v.translatesAutoresizingMaskIntoConstraints = false
			addSubview(v)
		}
		NSLayoutConstraint.activate([
			picker.topAnchor.constraint(equalTo: topAnchor, constant: 6),
			leading ? picker.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8)
				: picker.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 8),
			hideButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
			hideButton.centerYAnchor.constraint(equalTo: picker.centerYAnchor),
			hideButton.leadingAnchor.constraint(greaterThanOrEqualTo: picker.trailingAnchor, constant: 8),
			separator.topAnchor.constraint(equalTo: picker.bottomAnchor, constant: 6),
			separator.leadingAnchor.constraint(equalTo: leadingAnchor),
			separator.trailingAnchor.constraint(equalTo: trailingAnchor),
			body.topAnchor.constraint(equalTo: separator.bottomAnchor),
			body.leadingAnchor.constraint(equalTo: leadingAnchor),
			body.trailingAnchor.constraint(equalTo: trailingAnchor),
			body.bottomAnchor.constraint(equalTo: bottomAnchor),
		])
		if !leading { picker.centerXAnchor.constraint(equalTo: centerXAnchor).isActive = true }
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
		if let content = contents[index] {
			content.translatesAutoresizingMaskIntoConstraints = false
			body.addSubview(content)
			NSLayoutConstraint.activate([
				content.topAnchor.constraint(equalTo: body.topAnchor),
				content.bottomAnchor.constraint(equalTo: body.bottomAnchor),
				content.leadingAnchor.constraint(equalTo: body.leadingAnchor),
				content.trailingAnchor.constraint(equalTo: body.trailingAnchor),
			])
		} else {
			let empty = Self.emptyState(title: sections[index].emptyTitle, text: sections[index].emptyText)
			empty.translatesAutoresizingMaskIntoConstraints = false
			body.addSubview(empty)
			NSLayoutConstraint.activate([
				empty.centerXAnchor.constraint(equalTo: body.centerXAnchor),
				empty.centerYAnchor.constraint(equalTo: body.centerYAnchor),
				empty.leadingAnchor.constraint(equalTo: body.leadingAnchor, constant: 16),
			])
		}
		UserDefaults.standard.set(index, forKey: defaultsKey)
	}

	/// Shows `view` as the section's content. A view shared by several panels (the project's
	/// terminal in each tab) moves into this one; call again when this panel comes to the front.
	func setContent(_ view: NSView, at index: Int) {
		contents[index] = view
		if selected == index, view.superview !== body { select(index) }
	}

	@objc private func picked(_ sender: NSSegmentedControl) { select(sender.selectedSegment) }

	/// An empty state: what belongs here and, optionally, a button that adds it.
	static func emptyState(title titleText: String, text emptyText: String, button: NSButton? = nil) -> NSView {
		let title = NSTextField(labelWithString: titleText)
		title.font = .systemFont(ofSize: NSFont.systemFontSize + 2, weight: .semibold)
		title.textColor = .secondaryLabelColor
		let text = NSTextField(wrappingLabelWithString: emptyText)
		text.textColor = .secondaryLabelColor
		text.alignment = .center
		let stack = NSStackView(views: [title, text])
		stack.orientation = .vertical
		stack.alignment = .centerX
		stack.spacing = 4
		if let button {
			stack.addArrangedSubview(button)
			stack.setCustomSpacing(12, after: text)
		}
		return stack
	}
}

extension PanelView {
	/// Right panel (an AppKit inspector item): saved databases and server browsers (phases 6 and 6b fill them).
	static func inspector(project: Project) -> PanelView {
		let panel = PanelView(sections: [
			Section(title: L("Database"), symbol: "cylinder.split.1x2",
			        emptyTitle: L("No Databases"),
			        emptyText: L("Connections to MySQL, MariaDB, PostgreSQL and SQLite databases will appear here.")),
			Section(title: L("Server"), symbol: "server.rack",
			        emptyTitle: L("No Servers"),
			        emptyText: L("Files on servers connected over SFTP or FTPS will appear here.")),
		], label: L("Right Panel"), defaultsKey: "InspectorSection",
		   hide: (#selector(DocumentWindow.toggleRightPanel(_:)), "chevron.right", L("Hide Right Panel")))
		panel.setContent(SavedListView(.databases, project: project), at: 0)
		panel.setContent(SavedListView(.servers, project: project), at: 1)
		return panel
	}

	/// Bottom panel: the project's terminal, Find in Project, usages and the language servers.
	static let terminalSection = 0, searchSection = 1, usagesSection = 2, languageServersSection = 3

	static func bottom() -> PanelView {
		PanelView(sections: [
			Section(title: L("Terminal"), symbol: "terminal",
			        emptyTitle: L("No Terminal"),
			        emptyText: L("A terminal in the project folder will appear here.")),
			Section(title: L("Search"), symbol: "magnifyingglass",
			        emptyTitle: L("No Search"),
			        emptyText: L("Results of Find in Project will appear here.")),
			Section(title: L("Usages"), symbol: "arrow.up.left.and.arrow.down.right",
			        emptyTitle: L("No Usages"),
			        emptyText: L("Usages of a symbol found with Navigate › Find Usages will appear here.")),
			Section(title: L("Language Servers"), symbol: "gearshape.2",
			        emptyTitle: L("No Language Servers"),
			        emptyText: L("The state and log of gopls will appear here.")),
		], label: L("Bottom Panel"), defaultsKey: "BottomPanelSection", leading: true,
		   hide: (#selector(DocumentWindow.toggleBottomPanel(_:)), "chevron.down", L("Hide Bottom Panel")))
	}
}
