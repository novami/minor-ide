import AppKit
import SwiftTerm

/// The project's shell in the bottom panel (2b.4): one per project, shared by its tabs (the tab
/// in front shows it). A login shell of the user starts in the project folder, so PATH and the
/// rest of the environment come from the user's own profile.
///
/// Restricted Mode: the shell does not start by itself, because a prompt theme may run Git
/// in the folder (and Git can run code from an untrusted repository's config).
@MainActor
final class ProjectTerminal: NSObject {
	let view = NSView()
	private let project: Project
	private var terminal: TerminalView?
	private var placeholder: NSView?

	init(project: Project) {
		self.project = project
		super.init()
		view.setAccessibilityElement(false)
		if project.isTrusted { start() } else { showPlaceholder(exited: false) }
		project.onTrustChange.append { [weak self] in
			guard let self, self.project.isTrusted, self.terminal == nil, self.placeholder != nil else { return }
			self.start()
		}
	}

	var isRunning: Bool { terminal != nil }

	/// Puts the keyboard focus into the terminal (blinking cursor, ready to type).
	func focus() {
		guard let terminal, let window = view.window else { return }
		window.makeFirstResponder(terminal)
	}

	func start() {
		placeholder?.removeFromSuperview()
		placeholder = nil
		let term = TerminalView(frame: view.bounds)
		term.processDelegate = self
		term.optionAsMetaKey = false // ⌥ types characters (@, [, ] … on Czech and other layouts)
		term.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
		term.applyColors()
		fill(with: term)
		terminal = term
		let shell = Self.loginShell
		term.startProcess(executable: shell, args: [], environment: Self.environment,
		                  execName: "-" + (shell as NSString).lastPathComponent, // login shell
		                  currentDirectory: project.url.path)
	}

	/// Ends the shell (the project closed).
	func stop() {
		terminal?.processDelegate = nil
		terminal?.terminate()
		terminal = nil
	}

	private func fill(with child: NSView) {
		view.subviews.forEach { $0.removeFromSuperview() }
		child.translatesAutoresizingMaskIntoConstraints = false
		view.addSubview(child)
		NSLayoutConstraint.activate([
			child.topAnchor.constraint(equalTo: view.topAnchor),
			child.bottomAnchor.constraint(equalTo: view.bottomAnchor),
			child.leadingAnchor.constraint(equalTo: view.leadingAnchor),
			child.trailingAnchor.constraint(equalTo: view.trailingAnchor),
		])
	}

	private func showPlaceholder(exited: Bool) {
		let title = NSTextField(labelWithString: exited ? L("The Shell Exited") : L("Terminal Not Started"))
		title.font = .systemFont(ofSize: NSFont.systemFontSize + 2, weight: .semibold)
		title.textColor = .secondaryLabelColor
		let text = NSTextField(wrappingLabelWithString: exited
			? L("Start a new shell in the project folder.")
			: L("In Restricted Mode the terminal doesn’t start by itself, because the shell prompt may run Git in the project folder."))
		text.textColor = .secondaryLabelColor
		text.alignment = .center
		let button = NSButton(title: L("Start Terminal"), target: self, action: #selector(startClicked(_:)))
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
	}

	@objc private func startClicked(_ sender: Any?) {
		start()
		focus()
	}

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
	nonisolated func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
	nonisolated func hostCurrentDirectoryUpdate(source: SwiftTerm.TerminalView, directory: String?) {}

	nonisolated func processTerminated(source: SwiftTerm.TerminalView, exitCode: Int32?) {
		MainActor.assumeIsolated {
			let hadFocus = terminal.map { view.window?.firstResponder === $0 } ?? false
			terminal = nil
			showPlaceholder(exited: true)
			if hadFocus { view.window?.makeFirstResponder(nil) }
		}
	}
}

/// Terminal view in the system's text colors, following light and dark mode.
private final class TerminalView: LocalProcessTerminalView {
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
}
