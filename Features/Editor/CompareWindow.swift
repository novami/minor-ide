import AppKit

/// Unified diff of two versions of a file (disk vs. the editor), read only.
@MainActor
final class CompareWindow: NSObject, NSWindowDelegate {
	let window: NSWindow
	var onClose: (() -> Void)?

	init(title: String, old: String, new: String, oldLabel: String, newLabel: String) {
		window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 650),
		                  styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
		let scroll = NSTextView.scrollableTextView()
		let view = scroll.documentView as? NSTextView ?? NSTextView()
		view.isEditable = false
		view.textStorage?.setAttributedString(Self.diff(old: old, new: new, oldLabel: oldLabel, newLabel: newLabel))
		view.setAccessibilityLabel(Strings.compare.comparison)
		window.contentView = scroll
		window.title = title
		window.subtitle = Strings.compare.comparison
		window.isReleasedWhenClosed = false
		super.init()
		window.delegate = self
		window.center()
		window.makeKeyAndOrderFront(nil)
	}

	func windowWillClose(_ notification: Notification) { onClose?() }

	/// Unified line diff, removed lines red and added lines green.
	static func diff(old: String, new: String, oldLabel: String, newLabel: String) -> NSAttributedString {
		let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
		let text = NSMutableAttributedString()
		let lines = LineDiff.unified(old.components(separatedBy: "\n"), new.components(separatedBy: "\n"))
		text.append(NSAttributedString(string: "--- \(oldLabel)\n+++ \(newLabel)\n", attributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor]))
		if lines.isEmpty {
			text.append(NSAttributedString(string: Strings.compare.versionsIdentical, attributes: [.font: font, .foregroundColor: NSColor.labelColor]))
		}
		for (prefix, line) in lines {
			var attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.labelColor]
			switch prefix {
			case "@": attrs[.foregroundColor] = NSColor.secondaryLabelColor
			case "-": attrs[.backgroundColor] = NSColor.systemRed.withAlphaComponent(0.18)
			case "+": attrs[.backgroundColor] = NSColor.systemGreen.withAlphaComponent(0.18)
			default: break
			}
			text.append(NSAttributedString(string: (prefix == "@" ? "" : String(prefix)) + line + "\n", attributes: attrs))
		}
		return text
	}
}
