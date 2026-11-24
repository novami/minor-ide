import AVFoundation
import AppKit

/// Right-click menu, speech and the Services menu: what NSTextView offers for selected text.
/// The app supplies the localized menu (`contextMenuProvider`); AppKit appends Services.
extension EditorView: @preconcurrency NSServicesMenuRequestor {
	public override func menu(for event: NSEvent) -> NSMenu? {
		// A right click outside the selection moves the caret there first, as in text views.
		let point = convert(event.locationInWindow, from: nil)
		let offset = characterIndexInDocument(at: point)
		if !selections.all.contains(where: { $0.range.contains(offset) || $0.range.upperBound == offset && !$0.isEmpty }) {
			setSelections(SelectionSet(caret: offset))
		}
		return contextMenuProvider?(self)
	}

	/// Byte offset under a point in view coordinates.
	func characterIndexInDocument(at point: NSPoint) -> Int {
		guard let window else { return caret }
		let screen = window.convertPoint(toScreen: convert(point, to: nil))
		let utf16 = characterIndex(for: screen)
		return utf16 == NSNotFound ? caret : rope.byteOffset(ofUTF16: utf16)
	}

	/// Selected text, or the whole document without a selection (what Speech reads).
	var textForSpeech: String {
		let s = selections.primary
		return s.isEmpty ? rope.string : rope.string(in: s.range)
	}

	@objc public func startSpeaking(_ sender: Any?) {
		speech.stopSpeaking(at: .immediate)
		speech.speak(AVSpeechUtterance(string: textForSpeech))
	}

	@objc public func stopSpeaking(_ sender: Any?) {
		speech.stopSpeaking(at: .immediate)
	}

	// MARK: Services

	public override func validRequestor(forSendType sendType: NSPasteboard.PasteboardType?, returnType: NSPasteboard.PasteboardType?) -> Any? {
		let canSend = sendType == nil || (sendType == .string && selections.all.contains { !$0.isEmpty })
		let canReturn = returnType == nil || returnType == .string
		return canSend && canReturn ? self : super.validRequestor(forSendType: sendType, returnType: returnType)
	}

	public func writeSelection(to pboard: NSPasteboard, types: [NSPasteboard.PasteboardType]) -> Bool {
		let text = selections.all.filter { !$0.isEmpty }.map { rope.string(in: $0.range) }.joined(separator: "\n")
		guard !text.isEmpty, types.contains(.string) else { return false }
		pboard.clearContents()
		return pboard.setString(text, forType: .string)
	}

	public func readSelection(from pboard: NSPasteboard) -> Bool {
		guard let text = pboard.string(forType: .string) else { return false }
		insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
		return true
	}
}
