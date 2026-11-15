import AppKit
import EditorKit

/// Window whose File › Close (⌘W) closes the focused split pane before the window.
final class EditorWindow: NSWindow {
	/// Returns true when it closed a pane instead of the window.
	var closesPane: (() -> Bool)?

	override func performClose(_ sender: Any?) {
		// The close button closes the window; only the menu item (⌘W) closes a pane.
		if sender is NSMenuItem, closesPane?() == true { return }
		super.performClose(sender)
	}
}

/// The editor of a window split in two panes over one document (View › Split Editor).
extension DocumentWindow {
	static func makeScrollView(for editor: EditorView) -> NSScrollView {
		let scroll = NSScrollView()
		scroll.hasVerticalScroller = true
		scroll.backgroundColor = .textBackgroundColor // below the last line
		scroll.wantsLayer = true // clip view, gutter and editor draw into layers
		editor.autoresizingMask = [.width]
		scroll.documentView = editor
		GutterView.install(for: editor)
		return scroll
	}

	@objc func splitEditorSideBySide(_ sender: Any?) { split(vertical: true) }
	@objc func splitEditorTopAndBottom(_ sender: Any?) { split(vertical: false) }
	@objc func closeEditorSplit(_ sender: Any?) { _ = closeFocusedPane() }

	/// Opens the second pane on the focused pane's position, or changes the direction of an open split.
	func split(vertical: Bool) {
		editorSplit.isVertical = vertical
		let opening = splitEditor == nil
		if opening {
			let second = EditorView(document: editor.document, font: editor.font)
			configure(second)
			editorSplit.addSubview(Self.makeScrollView(for: second))
			splitEditor = second
		}
		editorSplit.layoutSubtreeIfNeeded()
		let total = vertical ? editorSplit.bounds.width : editorSplit.bounds.height
		editorSplit.setPosition(((total - editorSplit.dividerThickness) / 2).rounded(), ofDividerAt: 0)
		editorSplit.layoutSubtreeIfNeeded()
		guard let second = splitEditor else { return }
		if opening { second.adoptViewState(of: find.editor) }
		window.makeFirstResponder(second)
	}

	/// Closes the focused pane; false without a split. The first editor stays (the window is
	/// bound to it) and takes the position of the second pane when the first one closes.
	func closeFocusedPane() -> Bool {
		guard let second = splitEditor else { return false }
		if find.editor !== second { editor.adoptViewState(of: second) }
		second.enclosingScrollView?.removeFromSuperview()
		editor.document.detach(second)
		splitEditor = nil
		find.editor = editor
		window.makeFirstResponder(editor)
		return true
	}

	/// Settings shared by both panes.
	func configure(_ pane: EditorView) {
		pane.setAccessibilityLabel(L("Editor"))
		pane.contextMenuProvider = { _ in DocumentWindow.contextMenu() }
		pane.onFocus = { [weak self] focused in self?.find.editor = focused }
	}
}
