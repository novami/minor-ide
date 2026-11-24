import AppKit

/// A popup with styled text near a place in the editor (hover documentation, parameter info):
/// a borderless panel that never becomes key, so the editor keeps the keyboard. Long text
/// scrolls; links open in the browser.
@MainActor
final class InfoPopup: NSObject, NSTextViewDelegate {
	enum Placement { case below, above }

	static let maxWidth: CGFloat = 560
	static let maxHeight: CGFloat = 320

	/// The mouse left the panel.
	var onMouseExit: (() -> Void)?
	/// A clicked link the owner handles itself (returns true); web links open in the browser.
	var onLink: ((URL) -> Bool)?

	private let panel: NSPanel
	private let scroll = NSScrollView()
	private let text = NSTextView()
	private var anchor = NSRect.zero
	private var placement = Placement.below
	private weak var parentWindow: NSWindow?

	init(accessibilityLabel: String) {
		panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 50),
		                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
		super.init()
		panel.isOpaque = false
		panel.backgroundColor = .clear
		panel.hasShadow = true
		panel.isReleasedWhenClosed = false
		panel.hidesOnDeactivate = true
		let background = TrackingBackground()
		background.material = .menu
		background.state = .active
		background.wantsLayer = true
		background.layer?.cornerRadius = 6
		background.layer?.masksToBounds = true
		background.onExit = { [weak self] in self?.onMouseExit?() }
		panel.contentView = background
		text.isEditable = false
		text.isSelectable = true
		text.drawsBackground = false
		text.textContainerInset = NSSize(width: 6, height: 6)
		text.textContainer?.lineFragmentPadding = 2
		text.isVerticallyResizable = true
		text.delegate = self
		text.setAccessibilityLabel(accessibilityLabel)
		scroll.documentView = text
		scroll.drawsBackground = false
		scroll.hasVerticalScroller = true
		scroll.autohidesScrollers = true
		background.addSubview(scroll)
	}

	var isVisible: Bool { panel.isVisible }
	var frame: NSRect { panel.frame }
	var string: String { text.string }

	/// `rect`: screen rect of the place; the popup goes on the preferred side, the other when there is no room.
	func show(_ content: NSAttributedString, at rect: NSRect, placement: Placement, parent: NSWindow) {
		text.textStorage?.setAttributedString(content)
		anchor = rect
		self.placement = placement
		parentWindow = parent
		if panel.parent !== parent {
			panel.parent?.removeChildWindow(panel)
			parent.addChildWindow(panel, ordered: .above)
		}
		layout()
		text.scroll(.zero)
		panel.orderFront(nil)
	}

	/// The place moved (scrolling, typing).
	func move(to rect: NSRect) {
		anchor = rect
		guard panel.isVisible else { return }
		layout()
	}

	func hide() {
		guard panel.isVisible else { return }
		panel.parent?.removeChildWindow(panel)
		panel.orderOut(nil)
	}

	func contains(screenPoint point: NSPoint) -> Bool { panel.isVisible && panel.frame.contains(point) }

	private func layout() {
		guard let container = text.textContainer, let manager = text.layoutManager else { return }
		let inset = text.textContainerInset
		// Width: the text's natural width up to the maximum, then height for that width.
		container.size = NSSize(width: Self.maxWidth - 2 * inset.width, height: .greatestFiniteMagnitude)
		manager.ensureLayout(for: container)
		let natural = manager.usedRect(for: container)
		let width = min(Self.maxWidth, ceil(natural.width) + 2 * inset.width + 2 * container.lineFragmentPadding + 2)
		container.size = NSSize(width: width - 2 * inset.width, height: .greatestFiniteMagnitude)
		manager.ensureLayout(for: container)
		let textHeight = ceil(manager.usedRect(for: container).height) + 2 * inset.height
		let height = min(Self.maxHeight, textHeight)
		text.frame = NSRect(x: 0, y: 0, width: width, height: textHeight)
		scroll.frame = NSRect(x: 0, y: 0, width: width, height: height)

		let screen = (parentWindow?.screen ?? NSScreen.main)?.visibleFrame ?? .infinite
		let below = anchor.minY - height - 2, above = anchor.maxY + 2
		var y: CGFloat
		switch placement {
		case .below: y = below >= screen.minY ? below : above
		case .above: y = above + height <= screen.maxY ? above : below
		}
		y = max(screen.minY, min(y, screen.maxY - height))
		let x = max(screen.minX, min(anchor.minX - inset.width - container.lineFragmentPadding, screen.maxX - width))
		panel.setFrame(NSRect(x: x, y: y, width: width, height: height), display: true)
	}

	func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
		guard let url = (link as? URL) ?? (link as? String).flatMap(URL.init(string:)) else { return true }
		if onLink?(url) == true {
			hide()
			return true
		}
		guard ["http", "https"].contains(url.scheme?.lowercased()) else { return true }
		NSWorkspace.shared.open(url)
		hide()
		return true
	}
}

/// The panel's background that reports the mouse leaving it.
private final class TrackingBackground: NSVisualEffectView {
	var onExit: (() -> Void)?

	override func updateTrackingAreas() {
		super.updateTrackingAreas()
		if trackingAreas.isEmpty {
			addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil))
		}
	}

	override func mouseExited(with event: NSEvent) { onExit?() }
}
