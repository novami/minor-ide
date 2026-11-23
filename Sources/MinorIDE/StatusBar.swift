import AppKit
import Localization
import EditorKit
import MinorCore
import TextEngine

/// Bar under the editor (plan: UX › Stavový řádek): Git branch and cursor position on the left; language,
/// line endings, indentation and encoding (each a menu that changes it) and Restricted
/// Mode on the right. Shows the focused pane's file.
@MainActor
final class StatusBar: NSView {
	weak var owner: DocumentWindow?
	private let position = NSTextField(labelWithString: "")
	private let language = NSTextField(labelWithString: "")
	private let readOnly = NSTextField(labelWithString: Strings.statusBar.readOnly)
	private let lineEnding = StatusBar.popUp(Strings.format.lineEndings)
	private let indentation = StatusBar.popUp(Strings.format.indentation)
	private let encoding = StatusBar.popUp(Strings.format.encoding)
	private let restricted = NSButton()
	/// gopls progress, start, crash or a missing install (hidden while it runs idle).
	private let languageServer = NSButton()
	/// Shows or hides the bottom panel (project windows only); lit while it is shown.
	private let bottomPanel = NSButton()
	/// Checked-out Git branch (trusted project in a repository only).
	private let branchIcon = NSImageView()
	private let branch = NSTextField(labelWithString: "")
	private lazy var branchView = NSStackView(views: [branchIcon, branch])
	private var updatePending = false

	init() {
		super.init(frame: .zero)
		let separator = NSBox()
		separator.boxType = .separator
		for label in [position, language, readOnly, branch] {
			label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
			label.textColor = .secondaryLabelColor
			label.lineBreakMode = .byTruncatingTail
		}
		position.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
		restricted.title = Strings.statusBar.restrictedMode
		restricted.image = NSImage(systemSymbolName: "shield.lefthalf.filled", accessibilityDescription: nil)
		restricted.imagePosition = .imageLeading
		restricted.isBordered = false
		restricted.controlSize = .small
		restricted.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
		restricted.contentTintColor = .secondaryLabelColor
		restricted.target = self
		restricted.action = #selector(trustProject(_:))
		restricted.toolTip = Strings.statusBar.restrictedModeHint

		bottomPanel.image = NSImage(systemSymbolName: "rectangle.bottomthird.inset.filled", accessibilityDescription: Strings.panel.bottomPanel)
		bottomPanel.setButtonType(.toggle)
		bottomPanel.isBordered = false
		bottomPanel.controlSize = .small
		bottomPanel.target = self
		bottomPanel.action = #selector(toggleBottomPanel(_:))
		bottomPanel.isHidden = true
		setBottomPanelShown(false)

		branchIcon.image = NSImage(systemSymbolName: "arrow.triangle.branch", accessibilityDescription: nil)
		branchIcon.symbolConfiguration = .init(pointSize: NSFont.smallSystemFontSize, weight: .regular)
		branchIcon.contentTintColor = .secondaryLabelColor
		branchView.spacing = 3
		branchView.isHidden = true
		branchView.setAccessibilityElement(true)
		branchView.setAccessibilityRole(.staticText)
		branch.setContentCompressionResistancePriority(.defaultLow + 1, for: .horizontal)

		languageServer.isBordered = false
		languageServer.controlSize = .small
		languageServer.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
		languageServer.imagePosition = .imageLeading
		languageServer.lineBreakMode = .byTruncatingTail
		languageServer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
		languageServer.target = self
		languageServer.action = #selector(languageServerClicked(_:))
		languageServer.isHidden = true

		readOnly.toolTip = Strings.statusBar.largeFileReadOnly
		let right = NSStackView(views: [languageServer, restricted, readOnly, language, lineEnding, indentation, encoding])
		right.spacing = 10
		let row = NSStackView(views: [bottomPanel, branchView, position, right])
		row.distribution = .fill
		row.spacing = 12
		row.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 6)
		for view in [separator, row] as [NSView] {
			view.translatesAutoresizingMaskIntoConstraints = false
			addSubview(view)
		}
		NSLayoutConstraint.activate([
			separator.topAnchor.constraint(equalTo: topAnchor),
			separator.leadingAnchor.constraint(equalTo: leadingAnchor),
			separator.trailingAnchor.constraint(equalTo: trailingAnchor),
			row.topAnchor.constraint(equalTo: separator.bottomAnchor),
			row.leadingAnchor.constraint(equalTo: leadingAnchor),
			row.trailingAnchor.constraint(equalTo: trailingAnchor),
			row.bottomAnchor.constraint(equalTo: bottomAnchor),
			heightAnchor.constraint(equalToConstant: 24),
		])
		setContentHuggingPriority(.required, for: .vertical)
		setAccessibilityElement(true)
		setAccessibilityRole(.group)
		setAccessibilityLabel(Strings.statusBar.statusBar)
	}

	@available(*, unavailable)
	required init?(coder: NSCoder) { fatalError("not supported") }

	/// What the bar shows, for snapshot runs.
	var summary: String {
		[branchView.isHidden ? "" : branch.stringValue, position.stringValue, languageServer.isHidden ? "" : languageServer.title, restricted.isHidden ? "" : restricted.title, readOnly.isHidden ? "" : readOnly.stringValue, language.stringValue,
		 lineEnding.titleOfSelectedItem ?? lineEnding.itemTitle(at: 0), indentation.itemTitle(at: 0), encoding.itemTitle(at: 0)]
			.filter { !$0.isEmpty }.joined(separator: " | ")
	}

	/// A borderless pull-down: its first item is the title showing the current value.
	private static func popUp(_ name: String) -> NSPopUpButton {
		let button = NSPopUpButton(frame: .zero, pullsDown: true)
		button.isBordered = false
		button.controlSize = .small
		button.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
		button.setAccessibilityLabel(name)
		return button
	}

	/// Called on every caret move or edit: only the position changes, once per run loop turn
	/// (the menus are rebuilt by `update` when the file or its format changes).
	func setNeedsUpdate() {
		guard !updatePending else { return }
		updatePending = true
		RunLoop.main.perform { [weak self] in
			MainActor.assumeIsolated {
				self?.updatePending = false
				self?.updatePosition()
			}
		}
	}

	private func updatePosition() {
		guard let owner else { return }
		let text = Self.position(owner.focusedPane.editor)
		if position.stringValue != text { position.stringValue = text }
	}

	func update() {
		guard let owner else { return }
		let pane = owner.focusedPane, doc = pane.document, format = doc.format
		updatePosition()
		language.stringValue = doc.text.language?.name ?? Strings.format.plainText
		restricted.isHidden = owner.project.map { $0.isTrusted } ?? true
		updateGitHead()
		readOnly.isHidden = !doc.text.isReadOnly
		lineEnding.isEnabled = !doc.text.isReadOnly
		encoding.isEnabled = !doc.text.isReadOnly

		let eol = doc.mixedLineEndings ? Strings.statusBar.mixedLineEndings(lineEnding: format.lineEnding.label) : format.lineEnding.label
		fill(lineEnding, title: eol, [(Strings.format.lineEndingLF, "lf"), (Strings.format.lineEndingCRLF, "crlf"), (Strings.format.lineEndingCR, "cr")]
			.map { ($0.0, $0.1 == format.lineEnding.rawValue && !doc.mixedLineEndings, #selector(setLineEnding(_:)), $0.1 as Any) })

		let tabs = format.indentStyle == .tab
		var indent: [(String, Bool, Selector, Any)] = [(Strings.format.tabs, tabs, #selector(setIndent(_:)), 0)]
		indent += [2, 4].map { (Strings.statusBar.indentSpaces(size: $0), !tabs && format.indentSize == $0, #selector(setIndent(_:)), $0 as Any) }
		indent += [2, 4, 8].map { (Strings.statusBar.tabWidthValue(width: $0), format.tabWidth == $0, #selector(setTabWidth(_:)), $0 as Any) }
		fill(indentation, title: tabs ? Strings.statusBar.tabsWithWidth(width: format.tabWidth) : Strings.format.spaceCount(count: format.indentSize), indent)
		indentation.menu?.insertItem(.separator(), at: 4)
		indentation.menu?.addItem(.separator())
		indentation.menu?.addItem(withTitle: Strings.format.convertIndentation, action: #selector(EditorView.convertIndentation(_:)), keyEquivalent: "")
			.target = pane.editor

		fill(encoding, title: format.charset.rawValue.uppercased(), Charset.allCases.map {
			($0.rawValue.uppercased(), $0 == format.charset, #selector(setCharset(_:)), $0.rawValue as Any)
		})
		encoding.toolTip = Strings.statusBar.encodingHint
	}

	private func fill(_ button: NSPopUpButton, title: String, _ items: [(String, Bool, Selector, Any)]) {
		let menu = NSMenu()
		menu.addItem(withTitle: title, action: nil, keyEquivalent: "")
		for (name, on, action, value) in items {
			let item = menu.addItem(withTitle: name, action: action, keyEquivalent: "")
			item.target = self
			item.state = on ? .on : .off
			item.representedObject = value
		}
		button.menu = menu
	}

	/// "Line 3, Column 7", plus the selected length or the number of cursors.
	static func position(_ editor: EditorView) -> String {
		let rope = editor.rope, selections = editor.selections
		let primary = selections.primary
		let line = rope.line(containing: primary.head)
		let column = rope.utf16Offset(ofByte: primary.head) - rope.utf16Offset(ofByte: rope.offset(ofLine: line)) + 1
		var text = Strings.statusBar.lineColumn(line: line + 1, column: column)
		if selections.count > 1 {
			text += " · " + Strings.statusBar.cursorCount(count: selections.count)
		} else if !primary.isEmpty {
			let length = rope.utf16Offset(ofByte: primary.range.upperBound) - rope.utf16Offset(ofByte: primary.range.lowerBound)
			text += " · " + Strings.statusBar.selectedCharacters(count: length)
		}
		return text
	}

	// MARK: Actions (the focused pane's file)

	@objc private func setLineEnding(_ sender: NSMenuItem) {
		guard let raw = sender.representedObject as? String, let value = LineEnding(rawValue: raw) else { return }
		owner?.setLineEnding(value)
	}

	@objc private func setIndent(_ sender: NSMenuItem) {
		guard let owner, let size = sender.representedObject as? Int else { return }
		owner.setIndent(style: size == 0 ? .tab : .space, size: size == 0 ? owner.format.indentSize : size)
	}

	@objc private func setTabWidth(_ sender: NSMenuItem) {
		if let width = sender.representedObject as? Int { owner?.setTabWidth(width) }
	}

	@objc private func setCharset(_ sender: NSMenuItem) {
		guard let raw = sender.representedObject as? String, let charset = Charset(rawValue: raw) else { return }
		owner?.document.setCharset(charset)
	}

	/// Shows the project's checked-out branch (hidden without one).
	func updateGitHead() {
		guard let head = owner?.project?.gitHead else {
			branchView.isHidden = true
			return
		}
		branch.stringValue = head.label
		branchView.isHidden = false
		switch head {
		case .branch(let name):
			branchView.toolTip = Strings.statusBar.gitBranch(branch: name)
			branchView.setAccessibilityLabel(Strings.statusBar.gitBranch(branch: name))
		case .detached(let hash):
			branchView.toolTip = Strings.statusBar.detachedHead(commit: hash)
			branchView.setAccessibilityLabel(Strings.statusBar.detachedHead(commit: head.label))
		}
	}

	/// Called by the window whenever the bottom panel is shown or hidden.
	func setBottomPanelShown(_ shown: Bool) {
		bottomPanel.isHidden = owner?.project == nil
		bottomPanel.state = shown ? .on : .off
		bottomPanel.contentTintColor = shown ? .controlAccentColor : .secondaryLabelColor
		bottomPanel.toolTip = shown ? Strings.panel.hideBottomPanel : Strings.panel.showBottomPanel
	}

	/// The bottom panel button in window coordinates, nil when hidden (snapshot checks).
	var bottomPanelButtonFrame: NSRect? {
		bottomPanel.isHidden ? nil : bottomPanel.convert(bottomPanel.bounds, to: nil)
	}

	@objc private func toggleBottomPanel(_ sender: Any?) { owner?.toggleBottomPanel(sender) }

	/// Shows gopls when something is worth seeing: work in progress, starting, a crash or a
	/// missing install (which the click offers to install).
	func updateLanguageServer() {
		guard let services = owner?.project?.languageServers else {
			languageServer.isHidden = true
			return
		}
		let status = services.status
		var title: String?, symbol: String?, tint = NSColor.secondaryLabelColor
		switch status {
		case .idle, .locating, .server(.stopped):
			break
		case .missing(let goInstalled):
			title = goInstalled ? Strings.menu.installGopls : Strings.statusBar.goplsNotInstalled
			symbol = "exclamationmark.triangle"
			tint = .systemOrange
		case .installing:
			title = Strings.statusBar.installingGopls
		case .server(.starting), .server(.restarting):
			title = Strings.statusBar.startingGopls
		case .server(.running):
			title = services.progress.text.map { "gopls: " + $0 }
		case .server(.failed):
			title = Strings.statusBar.goplsStopped
			symbol = "exclamationmark.triangle"
			tint = .systemOrange
		}
		languageServer.isHidden = title == nil
		languageServer.title = title ?? ""
		languageServer.image = symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }
		languageServer.contentTintColor = tint
		languageServer.toolTip = "gopls — " + LanguageServersPanel.describe(status, progress: services.progress)
	}

	@objc private func languageServerClicked(_ sender: Any?) {
		guard let owner, let services = owner.project?.languageServers else { return }
		if services.status == .missing(goInstalled: true) {
			LanguageServersPanel.confirmInstall(services, in: owner.window)
		} else {
			owner.showLanguageServers()
		}
	}

	@objc private func trustProject(_ sender: Any?) { owner?.toggleProjectTrust(sender) }
}
