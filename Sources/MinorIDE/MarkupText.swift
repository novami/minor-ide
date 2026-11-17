import AppKit
import Highlight
import LSPKit

/// Server documentation as styled text: code blocks in the editor font with syntax colours,
/// prose with inline Markdown (code, emphasis, links), headings in bold.
@MainActor
enum MarkupText {
	static var textFont: NSFont { .systemFont(ofSize: NSFont.smallSystemFontSize + 1) }

	static func attributed(_ markup: Markup, codeFont: NSFont, appearance: NSAppearance) -> NSAttributedString {
		let out = NSMutableAttributedString()
		for block in markup.blocks {
			if out.length > 0 { out.append(NSAttributedString(string: "\n", attributes: [.font: textFont, .paragraphStyle: gap])) }
			switch block {
			case .code(let code, let language): out.append(self.code(code, language: language, font: codeFont, appearance: appearance))
			case .plain(let text): out.append(NSAttributedString(string: text, attributes: [.font: textFont, .foregroundColor: NSColor.labelColor]))
			case .markdown(let text): out.append(prose(text, codeFont: codeFont))
			}
		}
		return out
	}

	/// Space between blocks and paragraphs.
	private static let gap: NSParagraphStyle = {
		let style = NSMutableParagraphStyle()
		style.paragraphSpacing = 6
		return style
	}()

	static func code(_ code: String, language: String?, font: NSFont, appearance: NSAppearance) -> NSAttributedString {
		let plain: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.labelColor]
		guard let language, let lexer = Languages.language(forPath: "x." + language.lowercased())?.lexer else {
			return NSAttributedString(string: code, attributes: plain)
		}
		let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
		let theme = dark ? Theme.dark : Theme.light
		let bytes = Array(code.utf8)
		let out = NSMutableAttributedString()
		var done = 0
		// Appends bytes up to `end` (scalar boundaries: tokens never split a character).
		func append(_ end: Int, _ color: NSColor?) {
			guard end > done else { return }
			var attrs = plain
			if let color { attrs[.foregroundColor] = color }
			out.append(NSAttributedString(string: String(decoding: bytes[done..<end], as: UTF8.self), attributes: attrs))
			done = end
		}
		var state = LexState.start, tokens: [Token] = [], lineStart = 0
		while lineStart <= bytes.count {
			let end = bytes[lineStart...].firstIndex(of: 0x0A) ?? bytes.count
			tokens.removeAll(keepingCapacity: true)
			lexer.lex(Array(bytes[lineStart..<end])[...], state: &state, tokens: &tokens)
			for t in tokens {
				let start = lineStart + t.start
				guard start >= done else { continue }
				append(start, nil)
				append(min(start + t.length, end), theme.rgba(t.kind).map { NSColor(srgbRed: $0.0, green: $0.1, blue: $0.2, alpha: $0.3) })
			}
			lineStart = end + 1
		}
		append(bytes.count, nil)
		return out
	}

	/// Paragraphs split by blank lines; inside a paragraph lines join with a space except list
	/// items; lines indented by four spaces or a tab are code.
	static func prose(_ text: String, codeFont: NSFont) -> NSAttributedString {
		let out = NSMutableAttributedString()
		let mono = NSFont.monospacedSystemFont(ofSize: textFont.pointSize - 1, weight: .regular)
		var paragraph = ""
		func flush() {
			guard !paragraph.isEmpty else { return }
			if out.length > 0 { out.append(NSAttributedString(string: "\n", attributes: [.font: textFont, .paragraphStyle: gap])) }
			out.append(inline(paragraph, mono: mono))
			paragraph = ""
		}
		for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
			let line = raw.trimmingCharacters(in: .whitespaces)
			if line.isEmpty {
				flush()
			} else if raw.hasPrefix("    ") || raw.hasPrefix("\t") {
				if !paragraph.isEmpty, !paragraph.hasPrefix("    ") { flush() }
				// An indented block stays one paragraph of code lines.
				paragraph += (paragraph.isEmpty ? "" : "\n") + "    " + line
			} else if let heading = Self.heading(line) {
				flush()
				paragraph = "**" + heading + "**"
				flush()
			} else if paragraph.isEmpty || Self.isListItem(line) || paragraph.hasPrefix("    ") {
				if paragraph.hasPrefix("    ") { flush() }
				paragraph += (paragraph.isEmpty ? "" : "\n") + line
			} else {
				paragraph += " " + line
			}
		}
		flush()
		return out
	}

	private static func heading(_ line: String) -> String? {
		let hashes = line.prefix(while: { $0 == "#" })
		guard (1...6).contains(hashes.count), line.dropFirst(hashes.count).first == " " else { return nil }
		return line.dropFirst(hashes.count + 1).trimmingCharacters(in: .whitespaces)
	}

	private static func isListItem(_ line: String) -> Bool {
		if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("+ ") { return true }
		let digits = line.prefix(while: \.isNumber)
		return !digits.isEmpty && (line.dropFirst(digits.count).hasPrefix(". ") || line.dropFirst(digits.count).hasPrefix(") "))
	}

	/// Inline Markdown of one paragraph; an indented code paragraph is plain monospaced text.
	private static func inline(_ text: String, mono: NSFont) -> NSAttributedString {
		if text.hasPrefix("    ") {
			let code = text.split(separator: "\n").map { $0.dropFirst(4) }.joined(separator: "\n")
			return NSAttributedString(string: code, attributes: [.font: mono, .foregroundColor: NSColor.labelColor, .paragraphStyle: gap])
		}
		let base: [NSAttributedString.Key: Any] = [.font: textFont, .foregroundColor: NSColor.labelColor, .paragraphStyle: gap]
		guard let parsed = try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace,
		                                                                        failurePolicy: .returnPartiallyParsedIfPossible)) else {
			return NSAttributedString(string: text, attributes: base)
		}
		let out = NSMutableAttributedString()
		for run in parsed.runs {
			var attrs = base
			let intent = run.inlinePresentationIntent ?? []
			if intent.contains(.code) {
				attrs[.font] = mono
			} else {
				var traits: NSFontDescriptor.SymbolicTraits = []
				if intent.contains(.stronglyEmphasized) { traits.insert(.bold) }
				if intent.contains(.emphasized) { traits.insert(.italic) }
				if !traits.isEmpty {
					attrs[.font] = NSFont(descriptor: textFont.fontDescriptor.withSymbolicTraits(traits), size: textFont.pointSize) ?? textFont
				}
			}
			if intent.contains(.strikethrough) { attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
			if let link = run.link { attrs[.link] = link }
			out.append(NSAttributedString(string: String(parsed[run.range].characters), attributes: attrs))
		}
		return out
	}
}
