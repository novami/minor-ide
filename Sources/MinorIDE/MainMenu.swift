import AppKit
import EditorKit

/// Standard macOS menu bar (Apple HIG): app, File, Edit, Format, View, Window, Help.
/// Items without a responder that implements their action stay disabled automatically.
@MainActor
enum MainMenu {
	static func build(target: AppDelegate) -> NSMenu {
		let main = NSMenu()

		main.add(submenu: "MinorIDE") { m in
			m.item(L("About MinorIDE"), #selector(NSApplication.orderFrontStandardAboutPanel(_:)))
			m.addItem(.separator())
			m.item(L("Settings…"), #selector(AppDelegate.openUserSettings(_:)), ",", target: target)
			m.addItem(.separator())
			let services = m.item(L("Services"), nil)
			services.submenu = NSMenu()
			NSApp.servicesMenu = services.submenu
			m.addItem(.separator())
			m.item(L("Hide MinorIDE"), #selector(NSApplication.hide(_:)), "h")
			m.item(L("Hide Others"), #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option])
			m.item(L("Show All"), #selector(NSApplication.unhideAllApplications(_:)))
			m.addItem(.separator())
			m.item(L("Quit MinorIDE"), #selector(NSApplication.terminate(_:)), "q")
		}

		main.add(submenu: L("File")) { m in
			m.item(L("New"), #selector(AppDelegate.newDocument(_:)), "n", target: target)
			m.item(L("Open…"), #selector(AppDelegate.openDocument(_:)), "o", target: target)
			let recent = m.item(L("Open Recent"), nil)
			recent.submenu = RecentMenu(target: target)
			m.addItem(.separator())
			m.item(L("Close"), #selector(NSWindow.performClose(_:)), "w")
			m.item(L("Save"), #selector(AppDelegate.saveDocument(_:)), "s", target: target)
			m.item(L("Save As…"), #selector(AppDelegate.saveDocumentAs(_:)), "s", [.command, .shift], target: target)
		}

		main.add(submenu: L("Edit")) { m in
			m.item(L("Undo"), Selector(("undo:")), "z")
			m.item(L("Redo"), Selector(("redo:")), "z", [.command, .shift])
			m.addItem(.separator())
			m.item(L("Cut"), #selector(NSText.cut(_:)), "x")
			m.item(L("Copy"), #selector(NSText.copy(_:)), "c")
			m.item(L("Paste"), #selector(NSText.paste(_:)), "v")
			m.item(L("Select All"), #selector(NSText.selectAll(_:)), "a")
			m.item(L("Select Next Occurrence"), #selector(EditorView.selectNextOccurrence(_:)), "g", .control)
			m.item(L("Select All Occurrences"), #selector(EditorView.selectAllOccurrences(_:)), "g", [.control, .command])
			m.addItem(.separator())
			let up = String(UnicodeScalar(UInt16(NSUpArrowFunctionKey))!), down = String(UnicodeScalar(UInt16(NSDownArrowFunctionKey))!)
			m.item(L("Duplicate Line"), #selector(EditorView.duplicateLines(_:)), "d", [.command, .shift])
			m.item(L("Move Line Up"), #selector(EditorView.moveLinesUp(_:)), up, [.command, .option])
			m.item(L("Move Line Down"), #selector(EditorView.moveLinesDown(_:)), down, [.command, .option])
			m.item(L("Comment Selection"), #selector(EditorView.toggleComment(_:)), "/")
			m.addItem(.separator())
			let find = m.item(L("Find"), nil)
			find.submenu = NSMenu(title: L("Find"))
			find.submenu!.item(L("Find…"), #selector(DocumentWindow.showFind(_:)), "f")
			find.submenu!.item(L("Find and Replace…"), #selector(DocumentWindow.showFindAndReplace(_:)), "f", [.command, .option])
			find.submenu!.item(L("Find Next"), #selector(DocumentWindow.findNextMatch(_:)), "g")
			find.submenu!.item(L("Find Previous"), #selector(DocumentWindow.findPreviousMatch(_:)), "g", [.command, .shift])
			find.submenu!.item(L("Use Selection for Find"), #selector(DocumentWindow.useSelectionForFind(_:)), "e")
			find.submenu!.item(L("Use Selection for Replace"), #selector(DocumentWindow.useSelectionForReplace(_:)), "e", [.command, .shift])
			find.submenu!.item(L("Jump to Selection"), #selector(NSResponder.centerSelectionInVisibleArea(_:)), "j")
		}

		main.add(submenu: L("Format")) { m in
			let eol = m.item(L("Line Endings"), nil)
			eol.submenu = NSMenu()
			for (title, value) in [(L("LF (macOS, Unix)"), "lf"), (L("CRLF (Windows)"), "crlf"), (L("CR (Classic Mac)"), "cr")] {
				eol.submenu!.item(title, #selector(AppDelegate.setLineEnding(_:)), target: target).representedObject = value
			}
			let indent = m.item(L("Indentation"), nil)
			indent.submenu = NSMenu()
			for (title, tag) in [(L("Tabs"), 0), (L("2 Spaces"), 2), (L("4 Spaces"), 4)] {
				indent.submenu!.item(title, #selector(AppDelegate.setIndent(_:)), target: target).tag = tag
			}
			indent.submenu!.addItem(.separator())
			indent.submenu!.item(L("Convert Indentation"), #selector(EditorView.convertIndentation(_:)))
			let width = m.item(L("Tab Width"), nil)
			width.submenu = NSMenu()
			for w in [2, 4, 8] {
				width.submenu!.item("\(w)", #selector(AppDelegate.setTabWidth(_:)), target: target).tag = w
			}
		}

		main.add(submenu: L("View")) { m in
			let folding = m.item(L("Code Folding"), nil)
			folding.submenu = NSMenu(title: L("Code Folding"))
			let left = String(UnicodeScalar(UInt16(NSLeftArrowFunctionKey))!), right = String(UnicodeScalar(UInt16(NSRightArrowFunctionKey))!)
			folding.submenu!.item(L("Fold"), #selector(EditorView.fold(_:)), left, [.command, .option])
			folding.submenu!.item(L("Unfold"), #selector(EditorView.unfold(_:)), right, [.command, .option])
			folding.submenu!.item(L("Fold All"), #selector(EditorView.foldAll(_:)), left, [.command, .option, .shift])
			folding.submenu!.item(L("Unfold All"), #selector(EditorView.unfoldAll(_:)), right, [.command, .option, .shift])
			m.addItem(.separator())
			// AppKit adds only a hidden fn-key variant of this item, so the visible one must be ours.
			m.item(L("Enter Full Screen"), #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control])
		}

		main.add(submenu: L("Window")) { m in
			m.item(L("Minimize"), #selector(NSWindow.performMiniaturize(_:)), "m")
			m.item(L("Zoom"), #selector(NSWindow.performZoom(_:)))
			m.addItem(.separator())
			m.item(L("Bring All to Front"), #selector(NSApplication.arrangeInFront(_:)))
			NSApp.windowsMenu = m // AppKit appends the window list
		}

		main.add(submenu: L("Help")) { m in
			m.item(L("MinorIDE Help"), #selector(NSApplication.showHelp(_:)), "?")
			NSApp.helpMenu = m // AppKit adds the menu search field
		}
		return main
	}
}

/// File ▸ Open Recent, filled from NSDocumentController's recent list each time it opens.
@MainActor
final class RecentMenu: NSMenu, NSMenuDelegate {
	private weak var target: AppDelegate?

	init(target: AppDelegate) {
		self.target = target
		super.init(title: L("Open Recent"))
		delegate = self
	}

	@available(*, unavailable)
	required init(coder: NSCoder) { fatalError("not supported") }

	func menuNeedsUpdate(_ menu: NSMenu) {
		removeAllItems()
		for url in NSDocumentController.shared.recentDocumentURLs {
			let item = item(url.lastPathComponent, #selector(AppDelegate.openRecent(_:)), target: target)
			item.representedObject = url
			item.image = NSWorkspace.shared.icon(forFile: url.path)
			item.image?.size = NSSize(width: 16, height: 16)
		}
		if !items.isEmpty { addItem(.separator()) }
		item(L("Clear Menu"), #selector(NSDocumentController.clearRecentDocuments(_:)))
	}
}

private extension NSMenu {
	func add(submenu title: String, _ build: (NSMenu) -> Void) {
		let menu = NSMenu(title: title)
		build(menu)
		let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
		item.submenu = menu
		addItem(item)
	}

	@discardableResult
	func item(_ title: String, _ action: Selector?, _ key: String = "", _ modifiers: NSEvent.ModifierFlags = .command,
	          target: AnyObject? = nil) -> NSMenuItem {
		let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
		item.keyEquivalentModifierMask = modifiers
		item.target = target
		addItem(item)
		return item
	}
}
