import AppKit
import Carbon
import SwiftTerm

/// The project's shells in the bottom panel (2b.4), shared by the project's tabs (the tab in
/// front shows them). Each is a login shell of the user started in the project folder, so
/// PATH and the rest of the environment come from the user's own profile. Several shells
/// are tabs in a strip above the terminal; `exit` closes one.
///
/// Restricted Mode: the shell does not start by itself, because a prompt theme may run Git
/// in the folder (and Git can run code from an untrusted repository's config).
@MainActor
final class ProjectTerminal: NSObject {
	let view = NSView()
	private let project: Project
	private let strip = NSSegmentedControl()
	private let content = NSView()
	private var sessions: [(view: TerminalView, title: String?)] = []
	private var current = 0
	private var placeholder: NSView?
	private var stripHeight: NSLayoutConstraint!
	private var opened = 0

	init(project: Project) {
		self.project = project
		super.init()
		view.setAccessibilityElement(false)
		buildStrip()
		if project.isTrusted { start() } else { showPlaceholder(exited: false) }
		project.onTrustChange.append { [weak self] in
			guard let self, self.project.isTrusted, self.sessions.isEmpty, self.placeholder != nil else { return }
			self.start()
		}
		NotificationCenter.default.addObserver(self, selector: #selector(fontChanged(_:)), name: .editorFontDidChange, object: nil)
	}

	private func buildStrip() {
		strip.segmentStyle = .automatic
		strip.controlSize = .small
		strip.trackingMode = .selectOne
		strip.target = self
		strip.action = #selector(tabPicked(_:))
		strip.setAccessibilityLabel(Strings.terminal.tabs)
		let add = NSButton(image: NSImage.symbol("plus", Strings.menu.newTerminalTab), target: self, action: #selector(addClicked(_:)))
		add.isBordered = false
		add.controlSize = .small
		add.toolTip = Strings.menu.newTerminalTab
		let close = NSButton(image: NSImage.symbol("xmark", Strings.terminal.closeTab), target: self, action: #selector(closeClicked(_:)))
		close.isBordered = false
		close.controlSize = .small
		close.toolTip = Strings.terminal.closeTab
		let bar = NSStackView(views: [strip, add, close, NSView()])
		bar.spacing = 6
		bar.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 8)
		for v in [bar, content] as [NSView] {
			v.translatesAutoresizingMaskIntoConstraints = false
			view.addSubview(v)
		}
		stripHeight = bar.heightAnchor.constraint(equalToConstant: 0)
		bar.clipsToBounds = true
		NSLayoutConstraint.activate([
			bar.topAnchor.constraint(equalTo: view.topAnchor),
			bar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
			bar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
			stripHeight,
			content.topAnchor.constraint(equalTo: bar.bottomAnchor),
			content.leadingAnchor.constraint(equalTo: view.leadingAnchor),
			content.trailingAnchor.constraint(equalTo: view.trailingAnchor),
			content.bottomAnchor.constraint(equalTo: view.bottomAnchor),
		])
	}

	var isRunning: Bool { !sessions.isEmpty }

	/// Puts the keyboard focus into the terminal (blinking cursor, ready to type).
	func focus() {
		guard sessions.indices.contains(current), let window = view.window else { return }
		window.makeFirstResponder(sessions[current].view)
	}

	/// Starts another shell as a new tab (also the first one).
	func start() {
		placeholder?.removeFromSuperview()
		placeholder = nil
		let term = TerminalView(frame: content.bounds)
		term.processDelegate = self
		term.optionAsMetaKey = false // ⌥ types characters (@, [, ] … on Czech and other layouts)
		term.font = EditorView.editorFont
		term.applyColors()
		opened += 1
		sessions.append((term, nil))
		select(sessions.count - 1)
		let shell = Self.loginShell
		term.startProcess(executable: shell, args: [], environment: Self.environment,
		                  execName: "-" + (shell as NSString).lastPathComponent, // login shell
		                  currentDirectory: project.url.path)
	}

	private func select(_ index: Int) {
		current = index
		fill(with: sessions[index].view)
		updateStrip()
	}

	private func updateStrip() {
		strip.segmentCount = sessions.count
		for (i, s) in sessions.enumerated() {
			strip.setLabel(s.title ?? Strings.terminal.shellNumber(number: i + 1), forSegment: i)
			strip.setWidth(0, forSegment: i)
		}
		if sessions.indices.contains(current) { strip.selectedSegment = current }
		// The strip shows only with more than one shell.
		stripHeight.constant = sessions.count > 1 ? 28 : 0
	}

	@objc private func tabPicked(_ sender: NSSegmentedControl) {
		guard sessions.indices.contains(sender.selectedSegment) else { return }
		select(sender.selectedSegment)
		focus()
	}

	@objc private func addClicked(_ sender: Any?) { newTab() }

	/// View › New Terminal Tab and the strip's + button.
	func newTab() {
		start()
		focus()
	}

	@objc private func closeClicked(_ sender: Any?) {
		guard sessions.indices.contains(current) else { return }
		sessions[current].view.terminate()
		// processTerminated removes the tab.
	}

	@objc private func fontChanged(_ note: Notification) {
		for s in sessions { s.view.font = EditorView.editorFont }
	}

	/// Ends the shell (the project closed).
	func stop() {
		for s in sessions {
			s.view.processDelegate = nil
			s.view.terminate()
		}
		sessions = []
	}

	private func fill(with child: NSView) {
		content.subviews.forEach { $0.removeFromSuperview() }
		child.translatesAutoresizingMaskIntoConstraints = false
		content.addSubview(child)
		NSLayoutConstraint.activate([
			child.topAnchor.constraint(equalTo: content.topAnchor),
			child.bottomAnchor.constraint(equalTo: content.bottomAnchor),
			child.leadingAnchor.constraint(equalTo: content.leadingAnchor),
			child.trailingAnchor.constraint(equalTo: content.trailingAnchor),
		])
	}

	private func showPlaceholder(exited: Bool) {
		let title = NSTextField(labelWithString: exited ? Strings.terminal.shellExited : Strings.terminal.notStarted)
		title.font = .systemFont(ofSize: NSFont.systemFontSize + 2, weight: .semibold)
		title.textColor = .secondaryLabelColor
		let text = NSTextField(wrappingLabelWithString: exited
			? Strings.terminal.startShellHint
			: Strings.terminal.restrictedModeInfo)
		text.textColor = .secondaryLabelColor
		text.alignment = .center
		let button = NSButton(title: Strings.terminal.startTerminal, target: self, action: #selector(startClicked(_:)))
		let stack = NSStackView(views: [title, text, button])
		stack.orientation = .vertical
		stack.alignment = .centerX
		stack.spacing = 6
		stack.setCustomSpacing(12, after: text)
		let box = NSView()
		stack.translatesAutoresizingMaskIntoConstraints = false
		box.addSubview(stack)
		NSLayoutConstraint.activate([
			stack.centerXAnchor.constraint(equalTo: box.centerXAnchor),
			stack.centerYAnchor.constraint(equalTo: box.centerYAnchor),
			stack.leadingAnchor.constraint(greaterThanOrEqualTo: box.leadingAnchor, constant: 16),
		])
		fill(with: box)
		placeholder = box
		updateStrip()
	}

	@objc private func startClicked(_ sender: Any?) { newTab() }

	/// The user's login shell from the account database (what Terminal.app uses), else $SHELL.
	static var loginShell: String {
		if let pw = getpwuid(getuid()), let shell = pw.pointee.pw_shell, let path = String(validatingCString: shell),
		   FileManager.default.isExecutableFile(atPath: path) {
			return path
		}
		return ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
	}

	/// The app's environment for the shell, with the terminal type and a UTF-8 locale
	/// (an app opened from the Finder has no LANG, so Czech text would break).
	static var environment: [String] {
		var env = ProcessInfo.processInfo.environment
		env["TERM"] = "xterm-256color"
		env["COLORTERM"] = "truecolor"
		if env["LANG"] == nil, env["LC_ALL"] == nil, env["LC_CTYPE"] == nil { env["LANG"] = "en_US.UTF-8" }
		for key in env.keys where key.hasPrefix("MINORIDE_") { env[key] = nil } // the app's own debug switches
		return env.map { "\($0.key)=\($0.value)" }.sorted()
	}
}

extension ProjectTerminal: LocalProcessTerminalViewDelegate {
	nonisolated func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
	nonisolated func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
		MainActor.assumeIsolated {
			guard let i = sessions.firstIndex(where: { $0.view === source }) else { return }
			sessions[i].title = title.isEmpty ? nil : String(title.prefix(40))
			updateStrip()
		}
	}
	nonisolated func hostCurrentDirectoryUpdate(source: SwiftTerm.TerminalView, directory: String?) {}

	nonisolated func processTerminated(source: SwiftTerm.TerminalView, exitCode: Int32?) {
		MainActor.assumeIsolated {
			guard let i = sessions.firstIndex(where: { $0.view === source }) else { return }
			let hadFocus = view.window?.firstResponder === sessions[i].view
			sessions.remove(at: i)
			if sessions.isEmpty {
				showPlaceholder(exited: true)
				if hadFocus { view.window?.makeFirstResponder(nil) }
				return
			}
			select(min(i, sessions.count - 1))
			if hadFocus { focus() }
		}
	}
}

/// Terminal view in the system's text colors, following light and dark mode.
final class TerminalView: LocalProcessTerminalView {

	func applyColors() {
		effectiveAppearance.performAsCurrentDrawingAppearance {
			nativeBackgroundColor = .textBackgroundColor
			nativeForegroundColor = .textColor
			caretColor = .controlAccentColor
		}
	}

	override func viewDidChangeEffectiveAppearance() {
		super.viewDidChangeEffectiveAppearance()
		applyColors()
	}

	/// The terminal's own scroller stays visible while disabled; shown only with scrollback.
	override func viewWillDraw() {
		super.viewWillDraw()
		let hidden = !canScroll
		for case let scroller as NSScroller in subviews where scroller.isHidden != hidden { scroller.isHidden = hidden }
	}
}

/// MinorIDE › Secure Keyboard Entry: while a terminal has the keyboard focus in the active
/// app, other apps cannot read the keys typed (passwords at a shell prompt), as in Terminal.
@MainActor
enum SecureKeyboardEntry {
	private static let key = "SecureKeyboardEntry"
	private static var active = false

	static var isEnabled: Bool {
		get { UserDefaults.standard.bool(forKey: key) }
		set {
			UserDefaults.standard.set(newValue, forKey: key)
			update()
		}
	}

	/// Turns the system's secure input on or off to match (calls are counted, so balanced).
	static func update() {
		let wanted = isEnabled && NSApp.isActive && NSApp.keyWindow?.firstResponder is TerminalView
		guard wanted != active else { return }
		active = wanted
		if wanted { EnableSecureEventInput() } else { DisableSecureEventInput() }
	}

	/// Follows activation, key window and focus: checked after every event the app handles
	/// (a few comparisons).
	static func observe() {
		let center = NotificationCenter.default
		for name in [NSApplication.didUpdateNotification, NSApplication.didResignActiveNotification] {
			center.addObserver(forName: name, object: nil, queue: .main) { _ in MainActor.assumeIsolated { update() } }
		}
	}
}
