import AppKit
import Localization
import CoreImage

/// Author, project and donation links (About window, Help menu, Support window).
enum Links {
	static let author = "Michal Novák"
	static let website = URL(string: "https://www.novami.cz")!
	static let repository = URL(string: "https://github.com/novami/minor-ide")!
	static let newIssue = URL(string: "https://github.com/novami/minor-ide/issues/new")!
	static let sponsors = URL(string: "https://github.com/sponsors/novami")!
	static let bitcoin = "bc1qasvxqe0r76awkyklwjxsv5scrznxs08gtz7fzt"
}

extension AppDelegate {
	@objc func showAbout(_ sender: Any?) { AboutWindow.shared.show() }

	@objc func reportIssue(_ sender: Any?) { NSWorkspace.shared.open(Links.newIssue) }

	@objc func showSupport(_ sender: Any?) { SupportWindow.shared.show() }

	static func aboutCredits() -> NSAttributedString {
		let small = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
		let style = NSMutableParagraphStyle()
		style.alignment = .center
		style.paragraphSpacing = 6
		let base: [NSAttributedString.Key: Any] = [.font: small, .foregroundColor: NSColor.labelColor, .paragraphStyle: style]
		let text = NSMutableAttributedString()
		func add(_ s: String, _ attributes: [NSAttributedString.Key: Any] = [:]) {
			text.append(NSAttributedString(string: s, attributes: base.merging(attributes) { $1 }))
		}
		func link(_ s: String, _ url: URL) { add(s, [.link: url]) }
		let bold = [NSAttributedString.Key.font: NSFont.boldSystemFont(ofSize: NSFont.smallSystemFontSize)]

		add(Strings.about.author); add(Links.author, bold); add(" · "); link("www.novami.cz", Links.website); add("\n")
		add(Strings.about.license + " "); link(Strings.about.sourceCodeGithub, Links.repository); add("\n\n")

		add(Strings.about.thanks + "\n", bold)
		add(Strings.about.thanksTesters); link(Strings.about.issuesLink, Links.newIssue); add(".\n")
		add(Strings.about.thanksDevelopers + "\n")
		add(Strings.about.thanksProjects + "\n")
		add(Strings.about.terminal); link("SwiftTerm", URL(string: "https://github.com/migueldeicaza/SwiftTerm")!)
		add(" © Miguel de Icaza · ")
		if let license = Bundle.main.url(forResource: "SwiftTerm", withExtension: "txt", subdirectory: "Licenses") {
			link(Strings.about.mitLicense, license)
		} else {
			add(Strings.about.mitLicense)
		}
		return text
	}
}

/// MinorIDE › About MinorIDE: like the standard About panel, but wide enough for the credits,
/// with the copyright as the footer.
@MainActor
final class AboutWindow: NSObject {
	static let shared = AboutWindow()
	private var window: NSWindow?

	func show() {
		if window == nil { window = makeWindow() }
		window?.makeKeyAndOrderFront(nil)
	}

	private func makeWindow() -> NSWindow {
		let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 10),
		                      styleMask: [.titled, .closable], backing: .buffered, defer: false)
		window.title = ""
		window.titlebarAppearsTransparent = true
		window.isReleasedWhenClosed = false
		let info = Bundle.main.infoDictionary ?? [:]

		let icon = NSImageView(image: NSApp.applicationIconImage)
		NSLayoutConstraint.activate([icon.widthAnchor.constraint(equalToConstant: 96), icon.heightAnchor.constraint(equalToConstant: 96)])
		let name = NSTextField(labelWithString: "MinorIDE")
		name.font = .boldSystemFont(ofSize: 20)
		let short = info["CFBundleShortVersionString"] as? String ?? "0.0.0"
		let version = NSTextField(labelWithString: Strings.common.version(version: short))
		version.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
		version.textColor = .secondaryLabelColor
		version.isSelectable = true

		let credits = NSTextField(labelWithAttributedString: AppDelegate.aboutCredits())
		credits.isSelectable = true
		credits.allowsEditingTextAttributes = true // makes the links clickable
		credits.maximumNumberOfLines = 0
		credits.preferredMaxLayoutWidth = 460

		let separator = NSBox()
		separator.boxType = .separator
		let copyright = NSTextField(labelWithString: info["NSHumanReadableCopyright"] as? String ?? "© \(Links.author)")
		copyright.font = .systemFont(ofSize: NSFont.smallSystemFontSize - 1)
		copyright.textColor = .tertiaryLabelColor

		let stack = NSStackView(views: [icon, name, version, credits, separator, copyright])
		stack.orientation = .vertical
		stack.alignment = .centerX
		stack.spacing = 6
		stack.setCustomSpacing(10, after: icon)
		stack.setCustomSpacing(18, after: version)
		stack.setCustomSpacing(18, after: credits)
		stack.setCustomSpacing(10, after: separator)
		stack.edgeInsets = NSEdgeInsets(top: 8, left: 30, bottom: 16, right: 30)
		NSLayoutConstraint.activate([
			stack.widthAnchor.constraint(equalToConstant: 520),
			separator.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -60),
		])
		window.contentView = stack
		window.setContentSize(stack.fittingSize)
		window.center()
		return window
	}
}

/// Help › Support MinorIDE…: GitHub Sponsors and a Bitcoin address with a QR code.
@MainActor
final class SupportWindow: NSObject, NSWindowDelegate {
	static let shared = SupportWindow()
	private var window: NSWindow?
	private var copyButton: NSButton?

	func show() {
		if window == nil { window = makeWindow() }
		window?.makeKeyAndOrderFront(nil)
	}

	private func makeWindow() -> NSWindow {
		let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 10),
		                      styleMask: [.titled, .closable], backing: .buffered, defer: false)
		window.title = Strings.about.supportMinoride
		window.isReleasedWhenClosed = false

		let title = NSTextField(labelWithString: Strings.about.enjoyingMinoride)
		title.font = .boldSystemFont(ofSize: 15)
		let intro = NSTextField(wrappingLabelWithString: Strings.about.supportText)
		intro.alignment = .center
		intro.preferredMaxLayoutWidth = 420

		let sponsor = NSButton(title: Strings.about.sponsorGithub, target: self, action: #selector(openSponsors(_:)))
		sponsor.image = NSImage(systemSymbolName: "heart.fill", accessibilityDescription: nil)
		sponsor.imagePosition = .imageLeading
		sponsor.contentTintColor = .systemPink
		sponsor.bezelStyle = .push
		sponsor.controlSize = .large
		sponsor.keyEquivalent = "\r"

		let separator = NSBox()
		separator.boxType = .separator

		let btcTitle = NSTextField(labelWithString: Strings.about.sendBitcoin)
		btcTitle.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
		let qr = NSImageView(image: Self.qrCode("bitcoin:" + Links.bitcoin, size: 150))
		qr.wantsLayer = true
		qr.layer?.backgroundColor = NSColor.white.cgColor // dark mode: scanners need a light quiet zone
		qr.layer?.cornerRadius = 8
		qr.setAccessibilityLabel(Strings.about.bitcoinQRCode)
		NSLayoutConstraint.activate([qr.widthAnchor.constraint(equalToConstant: 170), qr.heightAnchor.constraint(equalToConstant: 170)])
		let address = NSTextField(labelWithString: Links.bitcoin)
		address.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
		address.isSelectable = true
		let copy = NSButton(title: Strings.about.copyAddress, target: self, action: #selector(copyAddress(_:)))
		copy.bezelStyle = .push
		copyButton = copy

		let stack = NSStackView(views: [title, intro, sponsor, separator, btcTitle, qr, address, copy])
		stack.orientation = .vertical
		stack.alignment = .centerX
		stack.spacing = 10
		stack.setCustomSpacing(16, after: intro)
		stack.setCustomSpacing(16, after: sponsor)
		stack.setCustomSpacing(16, after: separator)
		stack.edgeInsets = NSEdgeInsets(top: 22, left: 24, bottom: 22, right: 24)
		NSLayoutConstraint.activate([
			stack.widthAnchor.constraint(equalToConstant: 480),
			separator.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -48),
		])
		window.contentView = stack
		window.setContentSize(stack.fittingSize)
		window.center()
		window.delegate = self
		return window
	}

	@objc private func openSponsors(_ sender: Any?) { NSWorkspace.shared.open(Links.sponsors) }

	@objc private func copyAddress(_ sender: Any?) {
		NSPasteboard.general.clearContents()
		NSPasteboard.general.setString(Links.bitcoin, forType: .string)
		copyButton?.title = Strings.about.copied
	}

	func windowWillClose(_ notification: Notification) { copyButton?.title = Strings.about.copyAddress }

	/// Black-on-white QR code scaled with whole pixels (sharp at any size).
	static func qrCode(_ text: String, size: CGFloat) -> NSImage {
		guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return NSImage() }
		filter.setValue(Data(text.utf8), forKey: "inputMessage")
		filter.setValue("M", forKey: "inputCorrectionLevel")
		guard let output = filter.outputImage else { return NSImage() }
		let scale = max(1, (size * 2 / output.extent.width).rounded(.down)) // Retina
		let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
		let rep = NSCIImageRep(ciImage: scaled)
		let image = NSImage(size: NSSize(width: scaled.extent.width / 2, height: scaled.extent.height / 2))
		image.addRepresentation(rep)
		return image
	}
}
