import AppKit

/// Clone Git Repository… (welcome window, File menu): a sheet with the repository address
/// and the folder to clone into; `git clone` runs with its progress shown and can be
/// cancelled. The clone opens as a project in Restricted Mode, like any unknown folder.
@MainActor
final class CloneSheet: NSObject, NSTextFieldDelegate {
	private let panel: NSPanel
	private let address = NSTextField()
	private let location = NSPathControl()
	private let name = NSTextField()
	private let progress = NSProgressIndicator()
	private let status = NSTextField(wrappingLabelWithString: "")
	private let cloneButton = NSButton()
	private var cancel: CancelToken?
	private var onDone: ((URL) -> Void)?
	private static let parentKey = "CloneParentFolder"

	override init() {
		panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 520, height: 200), styleMask: [.titled], backing: .buffered, defer: true)
		super.init()
		address.placeholderString = "https://github.com/owner/repository.git"
		address.delegate = self
		address.setAccessibilityLabel(Strings.clone.repositoryAddress)
		name.delegate = self
		name.setAccessibilityLabel(Strings.clone.folderName)
		location.pathStyle = .popUp
		location.allowedTypes = ["public.folder"]
		location.url = Self.defaultParent
		location.setAccessibilityLabel(Strings.clone.cloneInto)
		progress.style = .bar
		progress.isIndeterminate = true
		progress.isHidden = true
		progress.minValue = 0
		progress.maxValue = 100
		status.textColor = .secondaryLabelColor
		status.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
		status.preferredMaxLayoutWidth = 480
		cloneButton.title = Strings.clone.clone
		cloneButton.bezelStyle = .rounded
		cloneButton.keyEquivalent = "\r"
		cloneButton.target = self
		cloneButton.action = #selector(clone(_:))
		cloneButton.isEnabled = false
		let cancelButton = NSButton(title: Strings.common.cancel, target: self, action: #selector(cancelPressed(_:)))
		cancelButton.keyEquivalent = "\u{1b}"

		let title = NSTextField(labelWithString: Strings.clone.title)
		title.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
		let grid = NSGridView(views: [
			[NSTextField(labelWithString: Strings.clone.repository), address],
			[NSTextField(labelWithString: Strings.clone.cloneIntoLabel), location],
			[NSTextField(labelWithString: Strings.clone.folderNameLabel), name],
		])
		grid.column(at: 0).xPlacement = .trailing
		grid.rowAlignment = .firstBaseline
		grid.rowSpacing = 8
		address.widthAnchor.constraint(equalToConstant: 380).isActive = true
		let buttons = NSStackView(views: [NSView(), cancelButton, cloneButton])
		let stack = NSStackView(views: [title, grid, progress, status, buttons])
		stack.orientation = .vertical
		stack.alignment = .leading
		stack.spacing = 12
		stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
		for v in [progress, status, buttons] { v.widthAnchor.constraint(equalTo: grid.widthAnchor).isActive = true }
		panel.contentView = stack
	}

	/// The last folder cloned into, else ~/Developer when it exists, else the home folder.
	private static var defaultParent: URL {
		let fm = FileManager.default
		if let saved = UserDefaults.standard.string(forKey: parentKey), fm.fileExists(atPath: saved) { return URL(fileURLWithPath: saved) }
		let developer = fm.homeDirectoryForCurrentUser.appendingPathComponent("Developer")
		return fm.fileExists(atPath: developer.path) ? developer : fm.homeDirectoryForCurrentUser
	}

	func begin(on window: NSWindow, onDone: @escaping (URL) -> Void) {
		self.onDone = onDone
		// A copied address is the likely one.
		if let copied = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
		   GitAddress.isValid(copied) {
			address.stringValue = copied
			addressChanged()
		}
		window.beginSheet(panel)
		panel.makeFirstResponder(address)
	}

	// MARK: Input

	func controlTextDidChange(_ obj: Notification) {
		if (obj.object as? NSTextField) === address { addressChanged() } else { validate() }
	}

	private var nameEdited = false

	private func addressChanged() {
		if !nameEdited || name.stringValue.isEmpty { name.stringValue = GitAddress.folderName(for: address.stringValue) }
		validate()
	}

	func controlTextDidEndEditing(_ obj: Notification) {
		if (obj.object as? NSTextField) === name { nameEdited = !name.stringValue.isEmpty }
	}

	private func validate() {
		let folder = name.stringValue
		cloneButton.isEnabled = cancel == nil && GitAddress.isValid(address.stringValue)
			&& !folder.isEmpty && !folder.contains("/") && folder != "." && folder != ".."
	}

	// MARK: Cloning

	@objc private func cancelPressed(_ sender: Any?) {
		if let cancel {
			cancel.cancel()
			status.stringValue = Strings.clone.cancelling
			return
		}
		close()
	}

	private func close() {
		panel.sheetParent?.endSheet(panel)
	}

	@objc private func clone(_ sender: Any?) {
		guard let parent = location.url else { return }
		let destination = parent.appendingPathComponent(name.stringValue)
		guard !FileManager.default.fileExists(atPath: destination.path) else {
			status.textColor = .systemRed
			status.stringValue = Strings.clone.alreadyExistsFolder(name: name.stringValue)
			return
		}
		UserDefaults.standard.set(parent.path, forKey: Self.parentKey)
		let token = CancelToken()
		cancel = token
		for field in [address, name] { field.isEnabled = false }
		location.isEnabled = false
		validate()
		progress.isHidden = false
		progress.isIndeterminate = true
		progress.startAnimation(nil)
		status.textColor = .secondaryLabelColor
		status.stringValue = Strings.clone.connecting
		let url = address.stringValue.trimmingCharacters(in: .whitespaces)
		let sink = CloneProgress(self)
		Task {
			guard let git = await ToolsModel.shared.gitTool() else {
				return finish(nil, error: Strings.clone.gitNotInstalled, destination: destination)
			}
			let result = await Task.detached(priority: .userInitiated) {
				// No hooks or transports that run commands; "--" so the address is never an option.
				git.run(["-c", "protocol.ext.allow=never", "-c", "core.hooksPath=/dev/null", "clone", "--progress", "--", url, destination.path],
				        in: parent, timeout: 3600, onStderr: { data in
				        	let text = String(decoding: data, as: UTF8.self)
				        	Task { @MainActor in sink.owner?.showProgress(text) }
				        }, cancel: token)
			}.value
			let error: String? = switch result {
			case nil: Strings.clone.gitNotStarted
			case let r? where r.status != 0:
				token.isCancelled ? Strings.clone.cloneWasCancelled : Self.lastLine(r.stderr)
			default: nil
			}
			finish(result?.status == 0 ? destination : nil, error: error, destination: destination)
		}
	}

	private static func lastLine(_ data: Data) -> String {
		let lines = String(decoding: data, as: UTF8.self).split(whereSeparator: { $0 == "\n" || $0 == "\r" })
		return lines.last(where: { $0.hasPrefix("fatal:") || $0.hasPrefix("error:") }).map(String.init)
			?? lines.last.map(String.init) ?? Strings.clone.cloneFailed
	}

	/// Git writes progress as "Receiving objects:  42% (…)\r".
	fileprivate func showProgress(_ text: String) {
		guard let line = text.split(whereSeparator: { $0 == "\r" || $0 == "\n" }).last else { return }
		status.stringValue = String(line)
		if let percent = line.firstRange(of: "%").map({ line[..<$0.lowerBound].split(separator: " ").last }).flatMap({ $0.flatMap { Double($0) } }) {
			progress.isIndeterminate = false
			progress.doubleValue = percent
		}
	}

	private func finish(_ cloned: URL?, error: String?, destination: URL) {
		cancel = nil
		progress.stopAnimation(nil)
		progress.isHidden = true
		if let cloned {
			close()
			onDone?(cloned)
			return
		}
		// A failed or cancelled clone leaves nothing behind.
		try? FileManager.default.removeItem(at: destination)
		for field in [address, name] { field.isEnabled = true }
		location.isEnabled = true
		status.textColor = .systemRed
		status.stringValue = error ?? ""
		validate()
	}
}

@MainActor
private final class CloneProgress {
	weak var owner: CloneSheet?
	init(_ owner: CloneSheet) { self.owner = owner }
}
