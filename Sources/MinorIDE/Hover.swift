import AppKit
import EditorKit
import LSPKit
import MinorCore
import TextEngine

/// Documentation of the symbol under the mouse (plan 3.7): after the mouse rests on a word for
/// half a second, the server's hover shows below it. It stays while the mouse is on the word or in
/// the popup (to scroll it or click a link) and closes on typing, a click, scrolling and Esc.
/// Edit › Show Documentation (F1) shows it for the symbol at the caret.
@MainActor
final class HoverController {
	private weak var editor: EditorView?
	private let endpoint: () -> (server: LanguageServer, uri: String)?
	private var popup: InfoPopup?
	private var askTask: Task<Void, Never>?
	private var hideTask: Task<Void, Never>?
	/// The word whose documentation shows; from the keyboard it does not follow the mouse.
	private var shown: (range: Range<Int>, byMouse: Bool)?
	private var observers: [NSObjectProtocol] = []
	private var generation = 0

	static let delay = Duration.milliseconds(500)

	init(editor: EditorView, endpoint: @escaping () -> (server: LanguageServer, uri: String)?) {
		self.editor = editor
		self.endpoint = endpoint
		editor.onMouseWord = { [weak self] in self?.mouseWord($0) }
	}

	var isShowing: Bool { popup?.isVisible ?? false }
	var isAvailable: Bool { endpoint()?.server.supportsHover ?? false }
	/// The shown text (snapshot checks).
	var debugText: String? { isShowing ? popup?.string : nil }

	// MARK: Events

	private func mouseWord(_ word: Range<Int>?) {
		askTask?.cancel()
		if let shown, shown.byMouse, isShowing, word != shown.range {
			// Moving towards the popup crosses other words: it closes only if the mouse ends up elsewhere.
			scheduleHideUnlessMouseInside()
		}
		guard let word, word != shown?.range, let end = endpoint(), end.server.supportsHover else { return }
		askTask = Task { [weak self] in
			try? await Task.sleep(for: Self.delay)
			guard !Task.isCancelled, let self, popup?.contains(screenPoint: NSEvent.mouseLocation) != true else { return }
			await ask(end, word: word, byMouse: true)
		}
	}

	private func scheduleHideUnlessMouseInside() {
		hideTask?.cancel()
		hideTask = Task { [weak self] in
			try? await Task.sleep(for: .milliseconds(250))
			guard !Task.isCancelled, let self, let shown, shown.byMouse else { return }
			if popup?.contains(screenPoint: NSEvent.mouseLocation) == true || editor?.mouseWord == shown.range { return }
			close()
		}
	}

	/// Edit › Show Documentation (F1): the symbol at the caret.
	func invoke() {
		guard let editor, let end = endpoint(), end.server.supportsHover else { return NSSound.beep() }
		var word = editor.rope.wordRange(at: editor.caret)
		if word.count > 200 { word = editor.caret..<editor.caret }
		askTask?.cancel()
		askTask = Task { [weak self] in await self?.ask(end, word: word, byMouse: false) }
	}

	/// Typing, a click or a caret move.
	func textOrCaretsChanged() {
		askTask?.cancel()
		editor?.mouseWord = nil // the next mouse move over a word starts again
		if isShowing { close() }
	}

	/// Esc while the documentation shows.
	func handle(_ selector: Selector) -> Bool {
		guard isShowing, selector == #selector(NSResponder.cancelOperation(_:)) else { return false }
		close()
		return true
	}

	func close() {
		askTask?.cancel()
		hideTask?.cancel()
		generation += 1
		shown = nil
		popup?.hide()
		for o in observers { NotificationCenter.default.removeObserver(o) }
		observers = []
	}

	// MARK: Request

	private func ask(_ end: (server: LanguageServer, uri: String), word: Range<Int>, byMouse: Bool) async {
		guard let editor else { return }
		generation += 1
		let gen = generation, rope = editor.rope, version = editor.document.version
		let hover = try? await end.server.hover(uri: end.uri, offset: word.lowerBound, in: rope)
		guard gen == generation, let editor = self.editor, editor.document.version == version,
		      !byMouse || editor.mouseWord == word else { return }
		guard let hover else { return byMouse ? () : NSSound.beep() }
		show(hover.contents, word: word, byMouse: byMouse)
	}

	private func show(_ markup: Markup, word: Range<Int>, byMouse: Bool) {
		guard let editor, let window = editor.window else { return }
		hideTask?.cancel()
		let popup = self.popup ?? InfoPopup(accessibilityLabel: L("Documentation"))
		self.popup = popup
		popup.onMouseExit = { [weak self] in self?.scheduleHideUnlessMouseInside() }
		shown = (word, byMouse)
		let text = MarkupText.attributed(markup, codeFont: editor.font, appearance: editor.effectiveAppearance)
		let from = editor.rope.utf16Offset(ofByte: word.lowerBound), to = editor.rope.utf16Offset(ofByte: word.upperBound)
		let rect = editor.firstRect(forCharacterRange: NSRange(location: from, length: to - from), actualRange: nil)
		popup.show(text, at: rect, placement: .below, parent: window)
		if !byMouse {
			NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested, userInfo: [
				.announcement: String(popup.string.prefix(600)), .priority: NSAccessibilityPriorityLevel.high.rawValue,
			])
		}
		guard observers.isEmpty else { return }
		let center = NotificationCenter.default
		observers.append(center.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in
			MainActor.assumeIsolated { self?.close() }
		})
		if let clip = editor.enclosingScrollView?.contentView {
			clip.postsBoundsChangedNotifications = true
			observers.append(center.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: .main) { [weak self] _ in
				MainActor.assumeIsolated { self?.close() }
			})
		}
	}
}

/// Parameter info (plan 3.7): typing a trigger character of the server ("(" or ",") outside
/// strings and comments shows the signature of the call above the caret, the parameter being
/// typed in bold with its documentation. It follows typing and caret moves and closes when the
/// caret leaves the call or on Esc. Edit › Show Parameter Info (⌃⇧Space) asks at the caret.
@MainActor
final class SignatureHelpController {
	private weak var editor: EditorView?
	private let endpoint: () -> (server: LanguageServer, uri: String)?
	private var popup: InfoPopup?
	private var help: SignatureHelp?
	private var task: Task<Void, Never>?
	private var generation = 0
	private var observers: [NSObjectProtocol] = []

	init(editor: EditorView, endpoint: @escaping () -> (server: LanguageServer, uri: String)?) {
		self.editor = editor
		self.endpoint = endpoint
	}

	var isShowing: Bool { popup?.isVisible ?? false }
	var isAvailable: Bool { endpoint()?.server.signatureHelpSupport != nil }
	/// The signature with the active parameter after "→" (snapshot checks).
	var debugText: String? {
		guard isShowing, let help else { return nil }
		let label = help.active.label as NSString
		let param = help.activeParameter.map { help.active.parameters[$0].range }
		return help.active.label + (param.map { " → " + label.substring(with: NSRange(location: $0.lowerBound, length: $0.count)) } ?? "")
	}

	// MARK: Events

	func typed(_ text: String) {
		guard text.utf8.count == 1, let c = text.utf8.first, let editor, let end = endpoint(),
		      let support = end.server.signatureHelpSupport else { return }
		if support.triggerCharacters.contains(c), !editor.typedInStringOrComment(editor.caret) {
			ask(.character(c), end)
		} else if help != nil, support.retriggerCharacters.contains(c) {
			ask(.character(c), end)
		}
	}

	/// Text or caret changed: while the help shows, it is asked again (null closes it).
	func textOrCaretsChanged() {
		guard help != nil, let end = endpoint() else { return }
		ask(.contentChange, end, delay: .milliseconds(40))
	}

	/// Edit › Show Parameter Info (⌃⇧Space).
	func invoke() {
		guard let end = endpoint(), end.server.signatureHelpSupport != nil else { return NSSound.beep() }
		ask(.invoked, end, beepIfNone: true)
	}

	/// Esc while the help shows.
	func handle(_ selector: Selector) -> Bool {
		guard isShowing, selector == #selector(NSResponder.cancelOperation(_:)) else { return false }
		close()
		return true
	}

	func close() {
		task?.cancel()
		generation += 1
		help = nil
		popup?.hide()
		for o in observers { NotificationCenter.default.removeObserver(o) }
		observers = []
	}

	// MARK: Request

	private func ask(_ trigger: SignatureHelpTrigger, _ end: (server: LanguageServer, uri: String),
	                 delay: Duration? = nil, beepIfNone: Bool = false) {
		task?.cancel()
		generation += 1
		let gen = generation, current = help
		task = Task { [weak self] in
			if let delay {
				try? await Task.sleep(for: delay)
				guard !Task.isCancelled else { return }
			}
			guard let editor = self?.editor else { return }
			let rope = editor.rope, caret = editor.caret, version = editor.document.version
			let result = try? await end.server.signatureHelp(uri: end.uri, offset: caret, in: rope, trigger: trigger, current: current)
			guard let self, gen == generation, let editor = self.editor,
			      editor.document.version == version, editor.caret == caret else { return }
			guard let result else {
				if beepIfNone { NSSound.beep() }
				return close()
			}
			show(result)
		}
	}

	private func show(_ result: SignatureHelp) {
		guard let editor, let window = editor.window else { return }
		let announce = help.map { $0.active.label != result.active.label } ?? true
		help = result
		let popup = self.popup ?? InfoPopup(accessibilityLabel: L("Parameter Info"))
		self.popup = popup
		popup.show(Self.text(result, font: editor.font, appearance: editor.effectiveAppearance),
		           at: caretRect(), placement: .above, parent: window)
		if announce {
			NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested, userInfo: [
				.announcement: result.active.label, .priority: NSAccessibilityPriorityLevel.medium.rawValue,
			])
		}
		guard observers.isEmpty else { return }
		let center = NotificationCenter.default
		observers.append(center.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in
			MainActor.assumeIsolated { self?.close() }
		})
		if let clip = editor.enclosingScrollView?.contentView {
			clip.postsBoundsChangedNotifications = true
			observers.append(center.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: .main) { [weak self] _ in
				MainActor.assumeIsolated { self?.followScroll() }
			})
		}
	}

	private func caretRect() -> NSRect {
		guard let editor else { return .zero }
		let utf16 = editor.rope.utf16Offset(ofByte: editor.caret)
		return editor.firstRect(forCharacterRange: NSRange(location: utf16, length: 0), actualRange: nil)
	}

	/// The help follows the caret; it hides while the caret is out of view.
	private func followScroll() {
		guard let popup, help != nil, let editor, let window = editor.window,
		      let clip = editor.enclosingScrollView?.contentView else { return }
		let rect = caretRect()
		let visible = window.convertToScreen(clip.convert(clip.bounds, to: nil))
		if visible.contains(NSPoint(x: rect.minX, y: rect.midY)) {
			if popup.isVisible { popup.move(to: rect) } else { show(help!) }
		} else {
			popup.hide()
		}
	}

	/// The signature in the editor font with the active parameter in bold, "2/3" before it when
	/// there are several; below it the parameter's documentation and the first paragraph of the
	/// signature's.
	static func text(_ help: SignatureHelp, font: NSFont, appearance: NSAppearance) -> NSAttributedString {
		let signature = help.active
		let out = NSMutableAttributedString()
		if help.signatures.count > 1 {
			out.append(NSAttributedString(string: "\(help.activeSignature + 1)/\(help.signatures.count)  ",
			                              attributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor]))
		}
		let label = NSMutableAttributedString(string: signature.label, attributes: [.font: font, .foregroundColor: NSColor.labelColor])
		var docs: [MarkupBlock] = []
		if let index = help.activeParameter {
			let param = signature.parameters[index]
			if !param.range.isEmpty, param.range.upperBound <= label.length {
				let bold = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
				label.addAttributes([.font: bold, .underlineStyle: NSUnderlineStyle.single.rawValue],
				                    range: NSRange(location: param.range.lowerBound, length: param.range.count))
			}
			docs += param.documentation?.blocks ?? []
		}
		out.append(label)
		if let first = signature.documentation?.blocks.first(where: { if case .code = $0 { false } else { true } }) {
			switch first {
			case .markdown(let s): docs.append(.markdown(firstParagraph(s)))
			case .plain(let s): docs.append(.plain(firstParagraph(s)))
			case .code: break
			}
		}
		if !docs.isEmpty {
			out.append(NSAttributedString(string: "\n", attributes: [.font: font]))
			let rest = NSMutableAttributedString(attributedString: MarkupText.attributed(Markup(blocks: docs), codeFont: font, appearance: appearance))
			rest.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: NSRange(location: 0, length: rest.length))
			out.append(rest)
		}
		return out
	}

	private static func firstParagraph(_ s: String) -> String {
		String(s.components(separatedBy: "\n\n").first ?? s)
	}
}
