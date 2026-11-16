import AppKit
import CoreText

extension Notification.Name {
	static let editorFontDidChange = Notification.Name("MinorIDE.editorFontDidChange")
}

/// One font for all editors (settings.json "font_family", "font_size"), changed live.
extension EditorView {
	public static let defaultFontSize: CGFloat = 13

	public static var editorFont: NSFont = .monospacedSystemFont(ofSize: defaultFontSize, weight: .regular) {
		didSet { if editorFont != oldValue { NotificationCenter.default.post(name: .editorFontDidChange, object: nil) } }
	}

	/// True when a connected display is not Retina. Decided by the displays, not by the
	/// window's screen, so moving a window between displays does not change the font.
	public static var hasNonRetinaDisplay: Bool {
		NSScreen.screens.contains { $0.backingScaleFactor < 2 }
	}

	/// The family at `size`. Without a family (or one not installed): Menlo when a display
	/// is not Retina — the system font's accents are thinner than a pixel there — else the
	/// system monospaced font.
	public static func font(family: String?, size: CGFloat?, nonRetina: Bool = hasNonRetinaDisplay) -> NSFont {
		let size = size.map { min(max($0, 6), 72) } ?? defaultFontSize
		if let family, let font = NSFontManager.shared.font(withFamily: family, traits: [], weight: 5, size: size) {
			return font
		}
		if nonRetina, let menlo = NSFont(name: "Menlo-Regular", size: size) { return menlo }
		return .monospacedSystemFont(ofSize: size, weight: .regular)
	}

	/// Installed fixed-pitch families, sorted.
	public static var monospacedFamilies: [String] {
		let names = NSFontManager.shared.availableFontNames(with: .fixedPitchFontMask) ?? []
		let families = Set(names.compactMap { NSFont(name: $0, size: 12)?.familyName }.filter { !$0.hasPrefix(".") })
		return families.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
	}

	struct Metrics {
		var ascent, lineHeight, gutterWidth, newlineWidth: CGFloat
		var attributes: [NSAttributedString.Key: Any]
		var ascii: AsciiGlyphs
	}

	static func metrics(_ font: NSFont) -> Metrics {
		let digitWidth = ("0" as NSString).size(withAttributes: [.font: font]).width
		return Metrics(
			ascent: ceil(CTFontGetAscent(font)),
			lineHeight: ceil(CTFontGetAscent(font) + CTFontGetDescent(font) + CTFontGetLeading(font)) + 3,
			gutterWidth: ceil(digitWidth * 7) + 16,
			newlineWidth: ceil(digitWidth / 2),
			attributes: [.font: font, .foregroundColor: NSColor.textColor],
			ascii: AsciiGlyphs(font: font as CTFont))
	}

	func observeFontSetting() {
		fontObserver = NotificationCenter.default.addObserver(forName: .editorFontDidChange, object: nil, queue: .main) { [weak self] _ in
			MainActor.assumeIsolated { self?.setFont(Self.editorFont) }
		}
	}

	/// Lays the text out again in `font`, keeping the caret's line in view.
	public func setFont(_ font: NSFont) {
		guard font != self.font else { return }
		adoptFont(font)
		gutter?.ruleThickness = gutterWidth
		gutter?.needsDisplay = true
		rebuildDisplay()
		updateSize()
		needsDisplay = true
		setNeedsCaretUpdate()
		scrollCaretVisible()
	}
}
