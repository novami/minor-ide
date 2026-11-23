import AppKit
import Localization
import MinorCore

/// Right-click menu of the file tree: create, rename, trash, reveal, copy paths.
extension ProjectSidebar: NSMenuDelegate {
	func installMenu() {
		let menu = NSMenu()
		menu.delegate = self
		outline.menu = menu
	}

	/// The clicked node, or the project root for a click below the rows.
	private var clickedNode: FileNode {
		(outline.clickedRow >= 0 ? outline.item(atRow: outline.clickedRow) as? FileNode : nil) ?? project.root
	}

	func menuNeedsUpdate(_ menu: NSMenu) {
		menu.removeAllItems()
		let node = clickedNode
		func add(_ title: String, _ action: Selector) {
			let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
			item.target = self
			item.representedObject = node
			menu.addItem(item)
		}
		if !node.isDirectory {
			add(Strings.sidebar.openInSplitEditor, #selector(openInSplit(_:)))
			menu.addItem(.separator())
		}
		add(Strings.sidebar.newFile, #selector(newFile(_:)))
		add(Strings.sidebar.newFolder, #selector(newFolder(_:)))
		if node !== project.root {
			menu.addItem(.separator())
			add(Strings.common.rename, #selector(rename(_:)))
			add(Strings.sidebar.moveToTrash, #selector(moveToTrash(_:)))
		}
		menu.addItem(.separator())
		add(Strings.common.showInFinder, #selector(showInFinder(_:)))
		add(Strings.sidebar.copyPath, #selector(copyPath(_:)))
		add(Strings.sidebar.copyRelativePath, #selector(copyRelativePath(_:)))
	}

	private func node(_ sender: Any?) -> FileNode? { (sender as? NSMenuItem)?.representedObject as? FileNode }

	/// Folder new items go into: the node itself or its parent.
	private func folder(of node: FileNode) -> FileNode { node.isDirectory ? node : (node.parent ?? project.root) }

	/// Asks for a name in a sheet; `done` gets a valid, unused name.
	private func askName(_ message: String, initial: String, in folder: URL, done: @escaping (String) -> Void) {
		let alert = NSAlert()
		alert.messageText = message
		let field = NSTextField(string: initial)
		field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
		alert.accessoryView = field
		alert.addButton(withTitle: Strings.common.ok)
		alert.addButton(withTitle: Strings.common.cancel)
		alert.window.initialFirstResponder = field
		guard let window = self.window else { return }
		alert.beginSheetModal(for: window) { response in
			MainActor.assumeIsolated {
				guard response == .alertFirstButtonReturn else { return }
				let name = field.stringValue.trimmingCharacters(in: .whitespaces)
				if name.isEmpty || name.contains("/") || name == "." || name == ".." {
					return self.fail(Strings.sidebar.invalidFileName(name: name))
				}
				if name != initial, FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path) {
					return self.fail(Strings.sidebar.alreadyExists(name: name))
				}
				done(name)
			}
		}
	}

	private func fail(_ message: String) {
		let alert = NSAlert()
		alert.messageText = message
		if let window { alert.beginSheetModal(for: window) }
	}

	private func refresh(_ folder: FileNode) {
		if folder.reload() { outline.reloadItem(folder, reloadChildren: true) }
		outline.expandItem(folder)
	}

	@objc private func newFile(_ sender: Any?) {
		guard let node = node(sender) else { return }
		let folder = folder(of: node)
		askName(Strings.sidebar.newFileName, initial: "", in: folder.url) { name in
			let url = folder.url.appendingPathComponent(name)
			guard FileManager.default.createFile(atPath: url.path, contents: Data()) else { return self.fail(Strings.sidebar.fileNotCreated) }
			self.refresh(folder)
			self.onOpen?(url)
		}
	}

	@objc private func newFolder(_ sender: Any?) {
		guard let node = node(sender) else { return }
		let folder = folder(of: node)
		askName(Strings.sidebar.newFolderName, initial: "", in: folder.url) { name in
			do {
				try FileManager.default.createDirectory(at: folder.url.appendingPathComponent(name), withIntermediateDirectories: false)
				self.refresh(folder)
			} catch {
				self.fail(error.localizedDescription)
			}
		}
	}

	@objc private func rename(_ sender: Any?) {
		guard let node = node(sender), let parent = node.parent else { return }
		askName(Strings.common.newName, initial: node.name, in: parent.url) { name in
			guard name != node.name else { return }
			let target = parent.url.appendingPathComponent(name)
			do {
				try FileManager.default.moveItem(at: node.url, to: target)
				self.onMoved?(node.url, target)
				self.refresh(parent)
			} catch {
				self.fail(error.localizedDescription)
			}
		}
	}

	@objc private func moveToTrash(_ sender: Any?) {
		guard let node = node(sender), let parent = node.parent else { return }
		do {
			try FileManager.default.trashItem(at: node.url, resultingItemURL: nil) // recoverable from the Trash
			refresh(parent)
		} catch {
			fail(error.localizedDescription)
		}
	}

	@objc private func openInSplit(_ sender: Any?) {
		guard let node = node(sender) else { return }
		onOpenInSplit?(node.url)
	}

	@objc private func showInFinder(_ sender: Any?) {
		guard let node = node(sender) else { return }
		NSWorkspace.shared.activateFileViewerSelecting([node.url])
	}

	@objc private func copyPath(_ sender: Any?) {
		guard let node = node(sender) else { return }
		copy(node.url.path)
	}

	@objc private func copyRelativePath(_ sender: Any?) {
		guard let node = node(sender) else { return }
		let root = project.url.path
		copy(node.url.path == root ? "." : String(node.url.path.dropFirst(root.count + 1)))
	}

	private func copy(_ text: String) {
		NSPasteboard.general.clearContents()
		NSPasteboard.general.setString(text, forType: .string)
	}
}
