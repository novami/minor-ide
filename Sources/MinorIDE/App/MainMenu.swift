import AppKit
import Localization
import Carbon
import EditorKit

/// Standard macOS menu bar (Apple HIG): app, File, Edit, Format, View, Window, Help.
/// Items without a responder that implements their action stay disabled automatically.
@MainActor
enum MainMenu {
	static func build(target: AppDelegate) -> NSMenu {
		let main = NSMenu()

		main.add(submenu: "MinorIDE") { m in
			m.item(Strings.menu.aboutMinoride, #selector(AppDelegate.showAbout(_:)), target: target)
			m.addItem(.separator())
			m.item(Strings.menu.settings, #selector(AppDelegate.showSettings(_:)), ",", target: target)
			m.item(Strings.menu.secureKeyboardEntry, #selector(AppDelegate.toggleSecureKeyboardEntry(_:)), target: target)
			m.addItem(.separator())
			let services = m.item(Strings.menu.services, nil)
			services.submenu = NSMenu()
			NSApp.servicesMenu = services.submenu
			m.addItem(.separator())
			m.item(Strings.menu.hideMinoride, #selector(NSApplication.hide(_:)), "h")
			m.item(Strings.menu.hideOthers, #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option])
			m.item(Strings.menu.showAll, #selector(NSApplication.unhideAllApplications(_:)))
			m.addItem(.separator())
			m.item(Strings.menu.quitMinoride, #selector(NSApplication.terminate(_:)), "q")
			// Title set in validateMenuItem: the opposite of the macOS setting for this quit.
			m.item(Strings.menu.quitAndKeepWindows, #selector(AppDelegate.quitTogglingKeepWindows(_:)), "q", [.command, .option], target: target).isAlternate = true
		}

		main.add(submenu: Strings.menu.file) { m in
			m.item(Strings.menu.new, #selector(AppDelegate.newDocument(_:)), "n", target: target)
			m.item(Strings.menu.open, #selector(AppDelegate.openDocument(_:)), "o", target: target)
			m.item(Strings.menu.openQuickly, #selector(DocumentWindow.openQuickly(_:)), "o", [.command, .shift])
			m.item(Strings.menu.cloneGitRepository, #selector(AppDelegate.cloneRepository(_:)), target: target)
			let recent = m.item(Strings.menu.openRecent, nil)
			recent.submenu = RecentMenu(target: target)
			m.addItem(.separator())
			m.item(Strings.menu.close, #selector(NSWindow.performClose(_:)), "w")
			m.item(Strings.menu.reopenClosedTab, #selector(AppDelegate.reopenClosedTab(_:)), "t", [.command, .shift], target: target)
			m.item(Strings.common.save, #selector(AppDelegate.saveDocument(_:)), "s", target: target)
			m.item(Strings.menu.saveAs, #selector(AppDelegate.saveDocumentAs(_:)), "s", [.command, .shift], target: target)
			m.item(Strings.menu.localHistoryEllipsis, #selector(DocumentWindow.showLocalHistory(_:)))
			m.addItem(.separator())
			m.item(Strings.menu.trustProject, #selector(DocumentWindow.toggleProjectTrust(_:)))
		}

		main.add(submenu: Strings.menu.edit) { m in
			m.item(Strings.menu.undo, Selector(("undo:")), "z")
			m.item(Strings.menu.redo, Selector(("redo:")), "z", [.command, .shift])
			m.addItem(.separator())
			m.item(Strings.common.cut, #selector(NSText.cut(_:)), "x")
			m.item(Strings.common.copy, #selector(NSText.copy(_:)), "c")
			m.item(Strings.common.paste, #selector(NSText.paste(_:)), "v")
			m.item(Strings.menu.selectAll, #selector(NSText.selectAll(_:)), "a")
			m.item(Strings.menu.selectNextOccurrence, #selector(EditorView.selectNextOccurrence(_:)), "g", .control)
			m.item(Strings.menu.selectAllOccurrences, #selector(EditorView.selectAllOccurrences(_:)), "g", [.control, .command])
			m.addItem(.separator())
			let up = functionKeyString(NSUpArrowFunctionKey), down = functionKeyString(NSDownArrowFunctionKey)
			m.item(Strings.menu.duplicateLine, #selector(EditorView.duplicateLines(_:)), "d", [.command, .shift])
			m.item(Strings.menu.moveLineUp, #selector(EditorView.moveLinesUp(_:)), up, [.command, .option])
			m.item(Strings.menu.moveLineDown, #selector(EditorView.moveLinesDown(_:)), down, [.command, .option])
			m.item(Strings.menu.showCompletions, #selector(EditorView.showCompletions(_:)), " ", .control)
			m.item(Strings.menu.showParameterInfo, #selector(DocumentWindow.showParameterInfo(_:)), " ", [.control, .shift])
			m.item(Strings.menu.showDocumentation, #selector(DocumentWindow.showDocumentation(_:)), functionKeyString(NSF1FunctionKey), [])
			KeyboardLayout.bind(m.item(Strings.menu.commentSelection, #selector(EditorView.toggleComment(_:)), "/"), keyCode: UInt16(kVK_ANSI_Slash))
			m.addItem(.separator())
			let find = m.item(Strings.common.find, nil)
			find.submenu = NSMenu(title: Strings.common.find)
			find.menuOrEmpty.item(Strings.find.findEllipsis, #selector(DocumentWindow.showFind(_:)), "f")
			find.menuOrEmpty.item(Strings.menu.findAndReplace, #selector(DocumentWindow.showFindAndReplace(_:)), "f", [.command, .option])
			find.menuOrEmpty.item(Strings.menu.findInProject, #selector(DocumentWindow.findInProject(_:)), "f", [.command, .shift])
			find.menuOrEmpty.item(Strings.find.findNext, #selector(DocumentWindow.findNextMatch(_:)), "g")
			find.menuOrEmpty.item(Strings.find.findPrevious, #selector(DocumentWindow.findPreviousMatch(_:)), "g", [.command, .shift])
			find.menuOrEmpty.item(Strings.menu.useSelectionForFind, #selector(DocumentWindow.useSelectionForFind(_:)), "e")
			find.menuOrEmpty.item(Strings.menu.useSelectionForReplace, #selector(DocumentWindow.useSelectionForReplace(_:)), "e", [.command, .shift])
			find.menuOrEmpty.item(Strings.menu.jumpToSelection, #selector(NSResponder.centerSelectionInVisibleArea(_:)), "j")
		}

		main.add(submenu: Strings.menu.format) { m in
			m.item(Strings.menu.formatCode, #selector(DocumentWindow.formatCode(_:)), "l", [.command, .option])
			m.addItem(.separator())
			let eol = m.item(Strings.format.lineEndings, nil)
			eol.submenu = NSMenu()
			for (title, value) in [(Strings.format.lineEndingLF, "lf"), (Strings.format.lineEndingCRLF, "crlf"), (Strings.format.lineEndingCR, "cr")] {
				eol.menuOrEmpty.item(title, #selector(AppDelegate.setLineEnding(_:)), target: target).representedObject = value
			}
			let indent = m.item(Strings.format.indentation, nil)
			indent.submenu = NSMenu()
			for (title, tag) in [(Strings.format.tabs, 0), (Strings.menu.twoSpaces, 2), (Strings.menu.fourSpaces, 4)] {
				indent.menuOrEmpty.item(title, #selector(AppDelegate.setIndent(_:)), target: target).tag = tag
			}
			indent.menuOrEmpty.addItem(.separator())
			indent.menuOrEmpty.item(Strings.format.convertIndentation, #selector(EditorView.convertIndentation(_:)))
			let width = m.item(Strings.menu.tabWidth, nil)
			width.submenu = NSMenu()
			for w in [2, 4, 8] {
				width.menuOrEmpty.item("\(w)", #selector(AppDelegate.setTabWidth(_:)), target: target).tag = w
			}
		}

		main.add(submenu: Strings.menu.view) { m in
			m.item(Strings.menu.showSidebar, #selector(NSSplitViewController.toggleSidebar(_:)), "s", [.command, .control])
			m.item(Strings.panel.showRightPanel, #selector(DocumentWindow.toggleRightPanel(_:)), "i", [.command, .control])
			KeyboardLayout.bind(m.item(Strings.panel.showBottomPanel, #selector(DocumentWindow.toggleBottomPanel(_:)), "`", .control), keyCode: UInt16(kVK_ANSI_Grave))
			KeyboardLayout.bind(m.item(Strings.menu.newTerminalTab, #selector(DocumentWindow.newTerminalTab(_:)), "`", [.control, .shift]), keyCode: UInt16(kVK_ANSI_Grave))
			m.addItem(.separator())
			m.item(Strings.menu.splitSideBySide, #selector(DocumentWindow.splitEditorSideBySide(_:)))
			m.item(Strings.menu.splitTopBottom, #selector(DocumentWindow.splitEditorTopAndBottom(_:)))
			m.item(Strings.menu.closeEditorSplit, #selector(DocumentWindow.closeEditorSplit(_:)))
			m.addItem(.separator())
			m.item(Strings.menu.wrapLines, #selector(AppDelegate.toggleWrapLines(_:)), target: target)
			m.item(Strings.menu.pinEnclosingLines, #selector(AppDelegate.toggleStickyLines(_:)), target: target)
			let folding = m.item(Strings.menu.codeFolding, nil)
			folding.submenu = NSMenu(title: Strings.menu.codeFolding)
			let left = functionKeyString(NSLeftArrowFunctionKey), right = functionKeyString(NSRightArrowFunctionKey)
			folding.menuOrEmpty.item(Strings.menu.fold, #selector(EditorView.fold(_:)), left, [.command, .option])
			folding.menuOrEmpty.item(Strings.menu.unfold, #selector(EditorView.unfold(_:)), right, [.command, .option])
			folding.menuOrEmpty.item(Strings.menu.foldAll, #selector(EditorView.foldAll(_:)), left, [.command, .option, .shift])
			folding.menuOrEmpty.item(Strings.menu.unfoldAll, #selector(EditorView.unfoldAll(_:)), right, [.command, .option, .shift])
			m.addItem(.separator())
			// AppKit adds only a hidden fn-key variant of this item, so the visible one must be ours.
			m.item(Strings.menu.enterFullScreen, #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control])
		}

		main.add(submenu: Strings.menu.navigate) { m in
			let left = functionKeyString(NSLeftArrowFunctionKey), right = functionKeyString(NSRightArrowFunctionKey)
			m.item(Strings.menu.back, #selector(DocumentWindow.navigateBack(_:)), left, [.command, .control])
			m.item(Strings.menu.forward, #selector(DocumentWindow.navigateForward(_:)), right, [.command, .control])
			m.item(Strings.menu.recentFiles, #selector(DocumentWindow.showRecentFiles(_:)), "e", [.command, .control])
			m.addItem(.separator())
			m.item(Strings.menu.jumpToDefinition, #selector(DocumentWindow.jumpToDefinition(_:)), "b")
			m.item(Strings.menu.jumpToImplementation, #selector(DocumentWindow.jumpToImplementation(_:)), "b", [.command, .option])
			m.item(Strings.menu.jumpToTypeDefinition, #selector(DocumentWindow.jumpToTypeDefinition(_:)), "b", [.command, .shift])
			m.item(Strings.menu.findUsages, #selector(DocumentWindow.findUsages(_:)), functionKeyString(NSF7FunctionKey), .option)
			m.addItem(.separator())
			let f2 = functionKeyString(NSF2FunctionKey)
			m.item(Strings.menu.nextProblem, #selector(DocumentWindow.nextProblem(_:)), f2, [])
			m.item(Strings.menu.previousProblem, #selector(DocumentWindow.previousProblem(_:)), f2, .shift)
			m.item(Strings.menu.showProblems, #selector(DocumentWindow.showProblems(_:)))
		}

		main.add(submenu: Strings.menu.refactor) { m in
			m.item(Strings.menu.quickActions, #selector(DocumentWindow.showQuickActions(_:)), "\r", .option)
			m.item(Strings.common.rename, #selector(DocumentWindow.renameSymbol(_:)), functionKeyString(NSF6FunctionKey), .shift)
		}

		main.add(submenu: Strings.menu.window) { m in
			m.item(Strings.menu.minimize, #selector(NSWindow.performMiniaturize(_:)), "m")
			m.item(Strings.menu.zoom, #selector(NSWindow.performZoom(_:)))
			m.addItem(.separator())
			m.item(Strings.menu.welcomeMinoride, #selector(AppDelegate.showWelcome(_:)), "1", [.command, .shift], target: target)
			m.addItem(.separator())
			m.item(Strings.menu.bringAllToFront, #selector(NSApplication.arrangeInFront(_:)))
			NSApp.windowsMenu = m // AppKit appends the window list
		}

		main.add(submenu: Strings.menu.help) { m in
			m.item(Strings.menu.minorideHelp, #selector(NSApplication.showHelp(_:)), "?")
			m.addItem(.separator())
			m.item(Strings.menu.reportIssue, #selector(AppDelegate.reportIssue(_:)), target: target)
			m.item(Strings.menu.supportMinoride, #selector(AppDelegate.showSupport(_:)), target: target)
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
		super.init(title: Strings.menu.openRecent)
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
		item(Strings.menu.clearMenu, #selector(NSDocumentController.clearRecentDocuments(_:)))
	}
}

extension NSMenu {
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
