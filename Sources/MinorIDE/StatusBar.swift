import AppKit
import EditorKit
import MinorCore
import TextEngine

/// Bar under the editor (plan: UX › Stavový řádek): cursor position on the left; language,
/// line endings, indentation and encoding (each a menu that changes it) and Restricted
/// Mode on the right. Shows the focused pane's file.
@MainActor
final class StatusBar: NSView {
	weak var owner: DocumentWindow?
	private let position = NSTextField(labelWithString: "")
	private let language = NSTextField(labelWithString: "")
	private let readOnly = NSTextField(labelWithString: L("Read Only"))
	private let lineEnding = StatusBar.popUp(L("Line Endings"))
	private let indentation = StatusBar.popUp(L("Indentation"))
	private let encoding = StatusBar.popUp(L("Encoding"))
	private let restricted = NSButton()
	private var updatePending = false

	init() {
		super.init(frame: .zero)
		let separator = NSBox()
		separator.boxType = .separator
		for label in [position, language, readOnly] {
			label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
			label.textColor = .secondaryLabelColor
			label.lineBreakMode = .byTruncatingTail
		}
		position.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
		restricted.title = L("Restricted Mode")
		restricted.image = NSImage(systemSymbolName: "shield.lefthalf.filled", accessibilityDescription: nil)
		restricted.imagePosition = .imageLeading
		restricted.isBordered = false
		restricted.controlSize = .small
		restricted.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
		restricted.contentTintColor = .secondaryLabelColor
		restricted.target = self
		restricted.action = #selector(trustProject(_:))
		restricted.toolTip = L("MinorIDE doesn’t run Git, tools or commands from this project. Click to trust it.")

		readOnly.toolTip = L("Files larger than 256 MB open read-only.")
		let right = NSStackView(views: [restricted, readOnly, language, lineEnding, indentation, encoding])
		right.spacing = 10
		let row = NSStackView(views: [position, right])
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
		setAccessibilityLabel(L("Status Bar"))
	}

	@available(*, unavailable)
	required init?(coder: NSCoder) { fatalError("not supported") }

	/// What the bar shows, for snapshot runs.
	var summary: String {
		[position.stringValue, restricted.isHidden ? "" : restricted.title, readOnly.isHidden ? "" : readOnly.stringValue, language.stringValue,
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
		language.stringValue = doc.text.language?.name ?? L("Plain Text")
		restricted.isHidden = owner.project.map { $0.isTrusted } ?? true
		readOnly.isHidden = !doc.text.isReadOnly
		lineEnding.isEnabled = !doc.text.isReadOnly
		encoding.isEnabled = !doc.text.isReadOnly

		let eol = doc.mixedLineEndings ? L("Mixed → %@", format.lineEnding.label) : format.lineEnding.label
		fill(lineEnding, title: eol, [(L("LF (macOS, Unix)"), "lf"), (L("CRLF (Windows)"), "crlf"), (L("CR (Classic Mac)"), "cr")]
			.map { ($0.0, $0.1 == format.lineEnding.rawValue && !doc.mixedLineEndings, #selector(setLineEnding(_:)), $0.1 as Any) })

		let tabs = format.indentStyle == .tab
		var indent: [(String, Bool, Selector, Any)] = [(L("Tabs"), tabs, #selector(setIndent(_:)), 0)]
		indent += [2, 4].map { (L("%d Spaces", $0), !tabs && format.indentSize == $0, #selector(setIndent(_:)), $0 as Any) }
		indent += [2, 4, 8].map { (L("Tab Width: %d", $0), format.tabWidth == $0, #selector(setTabWidth(_:)), $0 as Any) }
		fill(indentation, title: tabs ? L("Tabs (%d)", format.tabWidth) : LP("%d spaces", one: "%d space", format.indentSize), indent)
		indentation.menu?.insertItem(.separator(), at: 4)
		indentation.menu?.addItem(.separator())
		indentation.menu?.addItem(withTitle: L("Convert Indentation"), action: #selector(EditorView.convertIndentation(_:)), keyEquivalent: "")
			.target = pane.editor

		fill(encoding, title: format.charset.rawValue.uppercased(), Charset.allCases.map {
			($0.rawValue.uppercased(), $0 == format.charset, #selector(setCharset(_:)), $0.rawValue as Any)
		})
		encoding.toolTip = L("Encoding used when saving")
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
		var text = L("Line %d, Column %d", line + 1, column)
		if selections.count > 1 {
			text += " · " + LP("%d cursors", one: "%d cursor", selections.count)
		} else if !primary.isEmpty {
			let length = rope.utf16Offset(ofByte: primary.range.upperBound) - rope.utf16Offset(ofByte: primary.range.lowerBound)
			text += " · " + LP("%d characters selected", one: "%d character selected", length)
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

	@objc private func trustProject(_ sender: Any?) { owner?.toggleProjectTrust(sender) }
}
