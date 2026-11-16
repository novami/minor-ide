import AppKit
import TextEngine

/// Changes against Git HEAD in the gutter: a bar at its leading edge (green added, blue
/// modified, a red wedge where lines were deleted). A click on it shows the committed lines
/// and offers to revert the block.
extension EditorView {
	static let gitBarWidth: CGFloat = 3

	func drawGitChanges(_ ctx: CGContext, in rect: NSRect) {
		let changes = document.gitChanges
		guard !changes.isEmpty, let first = lines(inY: rect.minY, rect.maxY).first else { return }
		let last = line(atY: rect.maxY)
		// First change that can reach the drawn lines (changes are in line order).
		var lo = 0, hi = changes.count
		while lo < hi {
			let mid = (lo + hi) / 2
			if max(changes[mid].lines.upperBound, changes[mid].lines.lowerBound + 1) <= first { lo = mid + 1 } else { hi = mid }
		}
		for change in changes[lo...] {
			guard change.lines.lowerBound <= last + 1 else { break }
			ctx.setFillColor(Self.gitColor(change.kind).cgColor)
			let top = y(ofLine: min(change.lines.lowerBound, rope.lineCount - 1))
			if change.kind == .deleted {
				// A wedge on the boundary above the line after the deletion.
				let y = change.lines.lowerBound >= rope.lineCount ? top + lineHeight : top
				let h = min(lineHeight / 2, 8)
				ctx.beginPath()
				ctx.move(to: CGPoint(x: 0, y: y - h / 2))
				ctx.addLine(to: CGPoint(x: h, y: y))
				ctx.addLine(to: CGPoint(x: 0, y: y + h / 2))
				ctx.closePath()
				ctx.fillPath()
			} else {
				let bottom = y(ofLine: change.lines.upperBound - 1) + rowsHeight(ofLine: change.lines.upperBound - 1)
				ctx.fill(CGRect(x: 0, y: top, width: Self.gitBarWidth, height: bottom - top))
			}
		}
	}

	private func rowsHeight(ofLine line: Int) -> CGFloat {
		line + 1 < rope.lineCount ? y(ofLine: line + 1) - y(ofLine: line) : lineHeight
	}

	static func gitColor(_ kind: LineChange.Kind) -> NSColor {
		switch kind {
		case .added: .systemGreen
		case .modified: .systemBlue
		case .deleted: .systemRed
		}
	}

	/// The change drawn at an editor y (a deletion also answers on the line above it).
	func gitChange(atY y: CGFloat) -> LineChange? {
		let line = line(atY: y)
		return document.gitChanges.first { c in
			c.kind == .deleted ? (c.lines.lowerBound == line || c.lines.lowerBound == line + 1 && y >= self.y(ofLine: line) + lineHeight / 2)
				: c.lines.contains(line)
		}
	}

	/// The committed text of a change, as it would be put back.
	func committedText(of change: LineChange) -> String {
		guard let base = document.gitBase else { return "" }
		let lines = base[change.old].joined(separator: "\n")
		// The last line of the file has no newline after it.
		let toEnd = change.lines.upperBound >= rope.lineCount
		return change.old.isEmpty ? "" : (toEnd && change.old.upperBound >= base.count ? lines : lines + "\n")
	}

	/// Puts the committed lines back in place of the change (one undo step).
	public func revert(_ change: LineChange) {
		let start = change.lines.lowerBound < rope.lineCount ? rope.offset(ofLine: change.lines.lowerBound) : rope.byteCount
		var end = change.lines.upperBound < rope.lineCount ? rope.offset(ofLine: change.lines.upperBound) : rope.byteCount
		var text = committedText(of: change)
		// Deleting the last lines of the file also removes the newline before them.
		if change.kind == .added, change.lines.upperBound >= rope.lineCount, start > 0 {
			replace((start - 1)..<end, with: "")
			return
		}
		if change.kind == .deleted, change.lines.lowerBound >= rope.lineCount, !text.isEmpty {
			text = "\n" + text.dropLast(text.hasSuffix("\n") ? 1 : 0)
			end = start
		}
		replace(start..<end, with: text)
	}

	/// Popover over the gutter: the committed lines and Revert.
	func showGitChange(_ change: LineChange, from gutter: NSView, at y: CGFloat) {
		let popover = NSPopover()
		popover.behavior = .transient
		popover.contentViewController = GitChangeController(editor: self, change: change, popover: popover)
		let rect = NSRect(x: 0, y: y - lineHeight / 2, width: EditorView.gitBarWidth + 2, height: lineHeight)
		popover.show(relativeTo: rect, of: gutter, preferredEdge: .maxX)
	}
}

/// Content of the change popover.
@MainActor
private final class GitChangeController: NSViewController {
	private weak var editor: EditorView?
	private let change: LineChange
	private weak var popover: NSPopover?

	init(editor: EditorView, change: LineChange, popover: NSPopover) {
		self.editor = editor
		self.change = change
		self.popover = popover
		super.init(nibName: nil, bundle: nil)
	}

	@available(*, unavailable)
	required init?(coder: NSCoder) { fatalError("not supported") }

	override func loadView() {
		guard let editor else { view = NSView(); return }
		let title: String
		switch change.kind {
		case .added: title = L("Added lines")
		case .modified: title = L("Changed lines")
		case .deleted: title = L("Deleted lines")
		}
		let label = NSTextField(labelWithString: title)
		label.font = .boldSystemFont(ofSize: NSFont.smallSystemFontSize)
		let revert = NSButton(title: L("Revert"), target: self, action: #selector(revert(_:)))
		revert.controlSize = .small
		revert.bezelStyle = .rounded
		revert.toolTip = L("Put back the lines from the last commit")
		let header = NSStackView(views: [label, NSView(), revert])
		var views: [NSView] = [header]
		let committed = editor.committedText(of: change)
		if !committed.isEmpty {
			let text = NSTextView()
			text.isEditable = false
			text.drawsBackground = false
			text.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
			text.textColor = .secondaryLabelColor
			text.string = committed.hasSuffix("\n") ? String(committed.dropLast()) : committed
			text.isVerticallyResizable = true
			text.textContainer?.widthTracksTextView = false
			text.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
			text.isHorizontallyResizable = true
			text.setAccessibilityLabel(L("Lines in the last commit"))
			let scroll = NSScrollView()
			scroll.documentView = text
			scroll.hasVerticalScroller = true
			scroll.hasHorizontalScroller = true
			scroll.autohidesScrollers = true
			scroll.drawsBackground = false
			let lines = CGFloat(min(change.old.count, 15))
			scroll.heightAnchor.constraint(equalToConstant: lines * 15 + 8).isActive = true
			scroll.widthAnchor.constraint(equalToConstant: 460).isActive = true
			views.append(scroll)
		}
		let stack = NSStackView(views: views)
		stack.orientation = .vertical
		stack.alignment = .leading
		stack.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)
		header.widthAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true
		if views.count > 1 { header.widthAnchor.constraint(equalTo: views[1].widthAnchor).isActive = true }
		view = stack
	}

	@objc private func revert(_ sender: Any?) {
		popover?.close()
		editor?.revert(change)
	}
}
