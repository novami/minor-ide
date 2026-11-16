import AppKit
import LSPKit

/// Language Servers section of the bottom panel (shared by the project's tabs): the state of
/// gopls, Restart, Install when it is missing, and the server's log.
@MainActor
final class LanguageServersPanel {
	let view = NSView()
	private let services: LanguageServices
	private let title = NSTextField(labelWithString: "")
	private let install = NSButton(title: L("Install gopls…"), target: nil, action: nil)
	private let restart = NSButton(title: L("Restart"), target: nil, action: nil)
	private let textView = NSTextView()
	private let scrollView = NSScrollView()
	private var pending: [String] = []

	init(services: LanguageServices) {
		self.services = services
		title.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
		title.textColor = .secondaryLabelColor
		title.lineBreakMode = .byTruncatingTail
		title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
		for button in [install, restart] {
			button.controlSize = .small
			button.bezelStyle = .push
			button.target = self
		}
		install.action = #selector(installGopls(_:))
		restart.action = #selector(restartServer(_:))

		textView.isEditable = false
		textView.isSelectable = true
		textView.isRichText = false
		textView.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
		textView.textColor = .labelColor
		textView.drawsBackground = false
		textView.textContainerInset = NSSize(width: 6, height: 4)
		textView.isVerticallyResizable = true
		textView.autoresizingMask = [.width]
		textView.textContainer?.widthTracksTextView = true
		textView.setAccessibilityLabel(L("Language Server Log"))
		scrollView.documentView = textView
		scrollView.hasVerticalScroller = true
		scrollView.autohidesScrollers = true
		scrollView.drawsBackground = false

		let header = NSStackView(views: [title, install, restart])
		header.spacing = 8
		header.edgeInsets = NSEdgeInsets(top: 4, left: 10, bottom: 4, right: 10)
		for v in [header, scrollView] as [NSView] {
			v.translatesAutoresizingMaskIntoConstraints = false
			view.addSubview(v)
		}
		NSLayoutConstraint.activate([
			header.topAnchor.constraint(equalTo: view.topAnchor),
			header.leadingAnchor.constraint(equalTo: view.leadingAnchor),
			header.trailingAnchor.constraint(equalTo: view.trailingAnchor),
			scrollView.topAnchor.constraint(equalTo: header.bottomAnchor),
			scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
			scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
			scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
		])

		textView.string = services.log.map { $0 + "\n" }.joined()
		services.onLog = { [weak self] line in self?.append(line) }
		services.onUpdate.append { [weak self] in self?.update() }
		update()
	}

	/// Log lines arrive in bursts: they are added once per pass of the run loop.
	private func append(_ line: String) {
		pending.append(line)
		guard pending.count == 1 else { return }
		DispatchQueue.main.async { [weak self] in
			MainActor.assumeIsolated { self?.flush() }
		}
	}

	private func flush() {
		guard let storage = textView.textStorage, !pending.isEmpty else { return }
		let atEnd = scrollView.contentView.bounds.maxY >= textView.frame.maxY - 20
		let attributes: [NSAttributedString.Key: Any] = [.font: textView.font!, .foregroundColor: NSColor.labelColor]
		storage.append(NSAttributedString(string: pending.map { $0 + "\n" }.joined(), attributes: attributes))
		pending = []
		// Same limit as the log itself: the oldest lines go.
		let lines = storage.string.utf16.count
		if lines > 2_000_000 { storage.deleteCharacters(in: NSRange(location: 0, length: lines - 1_500_000)) }
		if atEnd { textView.scrollToEndOfDocument(nil) }
	}

	private func update() {
		let status = services.status
		title.stringValue = "gopls — " + Self.describe(status, progress: services.progress)
		install.isHidden = status != .missing(goInstalled: true)
		switch status {
		case .server:
			restart.title = L("Restart")
			restart.isHidden = false
		case .missing:
			restart.title = L("Check Again") // after installing gopls by hand
			restart.isHidden = false
		default:
			restart.isHidden = true
		}
	}

	/// The state in words, for the panel and the status bar tooltip.
	static func describe(_ status: LanguageServices.Status, progress: ProgressTracker) -> String {
		switch status {
		case .idle: L("Starts when you open a Go file")
		case .locating: L("Looking for gopls…")
		case .missing(true): L("Not installed. Install it with go install.")
		case .missing(false): L("Not installed. Install Go first, then gopls.")
		case .installing: L("Installing…")
		case .server(.starting): L("Starting…")
		case .server(.restarting(let attempt)): L("Restarting after a crash (%d of 3)…", attempt)
		case .server(.running): progress.text ?? L("Running")
		case .server(.stopped): L("Stopped")
		case .server(.failed): L("Stopped after repeated crashes. Click Restart to try again.")
		}
	}

	@objc private func restartServer(_ sender: Any?) { services.restart() }

	@objc private func installGopls(_ sender: Any?) {
		guard let window = view.window else { return }
		Self.confirmInstall(services, in: window)
	}

	/// Asks before downloading gopls (it runs `go install` from the internet).
	static func confirmInstall(_ services: LanguageServices, in window: NSWindow) {
		let alert = NSAlert()
		alert.messageText = L("Install gopls?")
		alert.informativeText = L("Go code intelligence needs gopls. MinorIDE runs “go install golang.org/x/tools/gopls@latest”, which downloads it from the Go module proxy into your Go bin folder.")
		alert.addButton(withTitle: L("Install"))
		alert.addButton(withTitle: L("Cancel"))
		alert.beginSheetModal(for: window) { response in
			guard response == .alertFirstButtonReturn else { return }
			MainActor.assumeIsolated { services.installGopls() }
		}
	}
}
