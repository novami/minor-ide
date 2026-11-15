import AppKit
import EditorKit
import TextEngine

/// Find bar above the editor in the style of the system one: search field, match count,
/// previous/next, options; a second row for replacing. Return finds the next match,
/// Shift+Return the previous, Esc closes the bar.
@MainActor
final class FindBar: NSView, NSSearchFieldDelegate {
	let controller: FindController
	/// Called when the bar closes (Esc, Done) so the editor gets the focus back.
	var onClose: (() -> Void)?

	let findField = NSSearchField()
	let replaceField = NSTextField()
	private let status = NSTextField(labelWithString: "")
	private let navigation = NSSegmentedControl()
	private let caseButton = FindBar.toggle("Aa", L("Match Case"))
	private let wordButton = FindBar.toggle("W", L("Whole Word"))
	private let regexButton = FindBar.toggle(".*", L("Regular Expression"))
	private let preserveButton = FindBar.toggle("AB", L("Preserve Case"))
	private var replaceRow: NSStackView!

	var showsReplace: Bool {
		get { !replaceRow.isHidden }
		set { replaceRow.isHidden = !newValue }
	}

	init(controller: FindController) {
		self.controller = controller
		super.init(frame: .zero)
		findField.placeholderString = L("Find")
		findField.delegate = self
		findField.sendsSearchStringImmediately = true
		findField.setAccessibilityLabel(L("Find"))
		replaceField.placeholderString = L("Replace")
		replaceField.delegate = self
		replaceField.setAccessibilityLabel(L("Replace"))

		navigation.segmentCount = 2
		navigation.trackingMode = .momentary
		navigation.segmentStyle = .separated
		navigation.setImage(NSImage(systemSymbolName: "chevron.left", accessibilityDescription: L("Find Previous")), forSegment: 0)
		navigation.setImage(NSImage(systemSymbolName: "chevron.right", accessibilityDescription: L("Find Next")), forSegment: 1)
		navigation.setToolTip(L("Find Previous"), forSegment: 0)
		navigation.setToolTip(L("Find Next"), forSegment: 1)
		navigation.target = self
		navigation.action = #selector(navigate(_:))

		status.textColor = .secondaryLabelColor
		status.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
		status.lineBreakMode = .byTruncatingTail
		status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
		for button in [caseButton, wordButton, regexButton, preserveButton] {
			button.target = self
			button.action = #selector(optionsChanged(_:))
		}
		let done = NSButton(title: L("Done"), target: self, action: #selector(close(_:)))
		done.bezelStyle = .rounded
		done.controlSize = .small
		let replaceButton = NSButton(title: L("Replace"), target: self, action: #selector(replace(_:)))
		let replaceAllButton = NSButton(title: L("All"), target: self, action: #selector(replaceAll(_:)))
		replaceAllButton.setAccessibilityLabel(L("Replace All"))
		replaceAllButton.toolTip = L("Replace All")
		for b in [replaceButton, replaceAllButton] {
			b.bezelStyle = .rounded
			b.controlSize = .small
		}
		for field in [findField, replaceField] as [NSTextField] {
			field.controlSize = .small
			field.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
			field.setContentHuggingPriority(.defaultLow, for: .horizontal)
		}
		navigation.controlSize = .small

		let findRow = NSStackView(views: [findField, status, caseButton, wordButton, regexButton, navigation, done])
		replaceRow = NSStackView(views: [replaceField, preserveButton, replaceButton, replaceAllButton])
		replaceRow.isHidden = true
		for row in [findRow, replaceRow!] {
			row.orientation = .horizontal
			row.spacing = 6
		}

		let rows = NSStackView(views: [findRow, replaceRow])
		rows.orientation = .vertical
		rows.alignment = .leading
		rows.spacing = 6
		rows.edgeInsets = NSEdgeInsets(top: 6, left: 8, bottom: 6, right: 8)
		rows.translatesAutoresizingMaskIntoConstraints = false
		let separator = NSBox()
		separator.boxType = .separator
		separator.translatesAutoresizingMaskIntoConstraints = false
		addSubview(rows)
		addSubview(separator)
		NSLayoutConstraint.activate([
			rows.leadingAnchor.constraint(equalTo: leadingAnchor),
			rows.trailingAnchor.constraint(equalTo: trailingAnchor),
			rows.topAnchor.constraint(equalTo: topAnchor),
			rows.bottomAnchor.constraint(equalTo: separator.topAnchor),
			findRow.trailingAnchor.constraint(equalTo: rows.trailingAnchor, constant: -8),
			separator.leadingAnchor.constraint(equalTo: leadingAnchor),
			separator.trailingAnchor.constraint(equalTo: trailingAnchor),
			separator.bottomAnchor.constraint(equalTo: bottomAnchor),
			status.widthAnchor.constraint(greaterThanOrEqualToConstant: 60),
			// Replace field lines up with the find field (needs the common ancestor above).
			replaceField.widthAnchor.constraint(equalTo: findField.widthAnchor),
		])
		setAccessibilityRole(.group)
		setAccessibilityLabel(L("Find"))
		controller.onUpdate = { [weak self] in self?.updateStatus() }
	}

	@available(*, unavailable)
	required init?(coder: NSCoder) { fatalError("not supported") }

	private static func toggle(_ title: String, _ name: String) -> NSButton {
		let b = NSButton(title: title, target: nil, action: nil)
		b.setButtonType(.pushOnPushOff)
		b.bezelStyle = .recessed
		b.controlSize = .small
		b.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
		b.toolTip = name
		b.setAccessibilityLabel(name)
		return b
	}

	/// Shows the query and options of the controller (after ⌘E or the find pasteboard).
	func syncFromController() {
		findField.stringValue = controller.query.text
		caseButton.state = controller.query.caseSensitive ? .on : .off
		wordButton.state = controller.query.wholeWord ? .on : .off
		regexButton.state = controller.query.regex ? .on : .off
		preserveButton.state = controller.preserveCase ? .on : .off
		replaceField.stringValue = controller.replacement
		updateStatus()
	}

	func updateStatus() {
		status.textColor = .secondaryLabelColor
		if controller.error != nil {
			status.stringValue = L("Invalid pattern")
			status.textColor = .systemRed
		} else if controller.query.text.isEmpty {
			status.stringValue = ""
		} else if controller.matches.isEmpty {
			status.stringValue = L("Not found")
		} else if let i = controller.currentIndex {
			status.stringValue = L("%d of %d", i + 1, controller.matches.count)
		} else {
			status.stringValue = LP("%d matches", one: "%d match", controller.matches.count)
		}
	}

	// MARK: Actions

	func controlTextDidChange(_ note: Notification) {
		if note.object as? NSTextField === findField {
			controller.origin = controller.editor.selections.primary.range.lowerBound
			controller.query.text = findField.stringValue
		} else {
			controller.replacement = replaceField.stringValue
		}
	}

	func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
		switch selector {
		case #selector(insertNewline(_:)):
			let back = NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false
			if control === replaceField {
				Task { await controller.replaceAndFind(); updateStatus() }
			} else {
				FindPasteboard.write(controller.query.text)
				Task { await controller.findNext(forward: !back) }
			}
			return true
		case #selector(cancelOperation(_:)):
			close(nil)
			return true
		default:
			return false
		}
	}

	@objc private func navigate(_ sender: NSSegmentedControl) {
		Task { await controller.findNext(forward: sender.selectedSegment == 1) }
	}

	@objc private func optionsChanged(_ sender: NSButton) {
		controller.preserveCase = preserveButton.state == .on
		var q = controller.query
		q.caseSensitive = caseButton.state == .on
		q.wholeWord = wordButton.state == .on
		q.regex = regexButton.state == .on
		controller.query = q
	}

	@objc private func replace(_ sender: Any?) {
		Task { await controller.replaceAndFind(); updateStatus() }
	}

	@objc private func replaceAll(_ sender: Any?) {
		Task {
			if await controller.replaceAll() == 0 { NSSound.beep() }
			updateStatus()
		}
	}

	@objc func close(_ sender: Any?) {
		FindPasteboard.write(controller.query.text)
		onClose?()
	}
}

/// The system-wide find pasteboard shared by Mac apps (⌘E in one app, ⌘G in another).
enum FindPasteboard {
	static func read() -> String? {
		NSPasteboard(name: .find).string(forType: .string)
	}

	static func write(_ text: String) {
		guard !text.isEmpty, text != read() else { return }
		let pb = NSPasteboard(name: .find)
		pb.clearContents()
		pb.setString(text, forType: .string)
	}
}
