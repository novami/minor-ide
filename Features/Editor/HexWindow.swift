import AppKit

/// Read-only hex view of a binary file (first 1 MB).
@MainActor
final class HexWindow: NSObject, NSWindowDelegate {
	let window: NSWindow
	var onClose: (() -> Void)?

	init(url: URL) {
		window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 600),
		                  styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
		let scroll = NSTextView.scrollableTextView()
		let text = scroll.documentView as? NSTextView ?? NSTextView()
		text.isEditable = false
		text.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
		let data = (try? Data(contentsOf: url, options: .alwaysMapped)) ?? Data()
		var dump = HexDump.format(data)
		if data.count > 1 << 20 { dump += "\n" + Strings.hex.truncated(size: data.count) }
		text.string = dump
		text.setAccessibilityLabel(Strings.hex.hexView)
		window.contentView = scroll
		window.title = url.lastPathComponent
		window.subtitle = Strings.hex.hexView
		window.representedURL = url
		window.isReleasedWhenClosed = false
		super.init()
		window.delegate = self
		window.center()
		window.makeKeyAndOrderFront(nil)
	}

	func windowWillClose(_ notification: Notification) { onClose?() }
}
