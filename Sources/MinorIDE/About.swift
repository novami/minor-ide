import AppKit
import CoreImage

/// Author, project and donation links (About panel, Help menu, Support window).
enum Links {
	static let author = "Michal Novák"
	static let website = URL(string: "https://www.novami.cz")!
	static let repository = URL(string: "https://github.com/novami/minor-ide")!
	static let newIssue = URL(string: "https://github.com/novami/minor-ide/issues/new")!
	static let sponsors = URL(string: "https://github.com/sponsors/novami")!
	static let bitcoin = "bc1qasvxqe0r76awkyklwjxsv5scrznxs08gtz7fzt"
}

extension AppDelegate {
	/// Standard About panel (HIG) with author, thanks and support in its credits.
	@objc func showAbout(_ sender: Any?) {
		NSApp.orderFrontStandardAboutPanel(options: [.credits: Self.aboutCredits()])
	}

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

		add(L("Author: ")); add(Links.author, bold); add(" · "); link("www.novami.cz", Links.website); add("\n")
		add(L("Free and open source under the MIT License.") + " "); link(L("Source code on GitHub"), Links.repository); add("\n\n")

		add(L("Thanks") + "\n", bold)
		add(L("To everyone who tests MinorIDE: please report bugs and ideas as ")); link(L("issues on GitHub"), Links.newIssue); add(".\n")
		add(L("To developers: pull requests from your fork are welcome.") + "\n")
		add(L("To the open source projects MinorIDE is built with: Swift, Go and SQLite.") + "\n")
		add(L("Terminal: ")); link("SwiftTerm", URL(string: "https://github.com/migueldeicaza/SwiftTerm")!)
		add(" © Miguel de Icaza · ")
		if let license = Bundle.main.url(forResource: "SwiftTerm", withExtension: "txt", subdirectory: "Licenses") {
			link(L("MIT License"), license)
		} else {
			add(L("MIT License"))
		}
		add("\n\n")

		add(L("Support MinorIDE") + "\n", bold)
		link(L("GitHub Sponsors"), Links.sponsors); add(" · " + L("Bitcoin:") + " ")
		add(Links.bitcoin, [.font: NSFont.monospacedSystemFont(ofSize: NSFont.smallSystemFontSize - 1, weight: .regular)])
		return text
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
		let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 10),
		                      styleMask: [.titled, .closable], backing: .buffered, defer: false)
		window.title = L("Support MinorIDE")
		window.isReleasedWhenClosed = false

		let title = NSTextField(labelWithString: L("Enjoying MinorIDE?"))
		title.font = .boldSystemFont(ofSize: 15)
		let intro = NSTextField(wrappingLabelWithString: L("MinorIDE is free and open source, made by one person in spare time. A small contribution helps keep it fast, native and growing. Thank you!"))
		intro.alignment = .center
		intro.preferredMaxLayoutWidth = 320

		let sponsor = NSButton(title: L("Sponsor on GitHub"), target: self, action: #selector(openSponsors(_:)))
		sponsor.image = NSImage(systemSymbolName: "heart.fill", accessibilityDescription: nil)
		sponsor.imagePosition = .imageLeading
		sponsor.contentTintColor = .systemPink
		sponsor.bezelStyle = .push
		sponsor.controlSize = .large
		sponsor.keyEquivalent = "\r"

		let separator = NSBox()
		separator.boxType = .separator

		let btcTitle = NSTextField(labelWithString: L("Or send Bitcoin"))
		btcTitle.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
		let qr = NSImageView(image: Self.qrCode("bitcoin:" + Links.bitcoin, size: 150))
		qr.wantsLayer = true
		qr.layer?.backgroundColor = NSColor.white.cgColor // dark mode: scanners need a light quiet zone
		qr.layer?.cornerRadius = 8
		qr.setAccessibilityLabel(L("QR code of the Bitcoin address"))
		NSLayoutConstraint.activate([qr.widthAnchor.constraint(equalToConstant: 170), qr.heightAnchor.constraint(equalToConstant: 170)])
		let address = NSTextField(labelWithString: Links.bitcoin)
		address.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
		address.isSelectable = true
		let copy = NSButton(title: L("Copy Address"), target: self, action: #selector(copyAddress(_:)))
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
		separator.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -48).isActive = true
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
		copyButton?.title = L("Copied")
	}

	func windowWillClose(_ notification: Notification) { copyButton?.title = L("Copy Address") }

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
