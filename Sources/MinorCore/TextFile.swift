import Foundation

/// What an existing file uses, so editing it does not silently change its conventions.
public struct DetectedFormat: Equatable, Sendable {
	public var lineEnding: LineEnding?
	public var mixedLineEndings = false
	public var indentStyle: IndentStyle?
	public var indentSize: Int?
}

/// A file decoded for editing: text with "\n" line endings only (the buffer never sees "\r"),
/// plus what is needed to write it back the same way.
public struct LoadedText: Sendable {
	public var text: String
	public var charset: Charset
	public var detected: DetectedFormat
	/// Lines as loaded, for trimming trailing whitespace only on lines the user changed.
	public var originalLines: Set<Substring>
}

public enum TextFile {
	/// A NUL byte in the first 8 KB marks a binary file (images, archives, compiled code).
	/// UTF-16 text has NULs too, so a UTF-16 byte order mark keeps it text.
	public static func looksBinary(_ data: Data) -> Bool {
		let head = data.prefix(8192)
		if head.starts(with: [0xFF, 0xFE]) || head.starts(with: [0xFE, 0xFF]) { return false }
		return head.contains(0)
	}

	/// Large (> 5 MB) or minified (a line over 10 000 bytes) files open without syntax
	/// colouring and analysis (plan, phase 1e).
	public static func needsSimplifiedMode(_ data: Data, maxBytes: Int = 5 << 20, maxLine: Int = 10_000) -> Bool {
		if data.count > maxBytes { return true }
		return data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) -> Bool in
			var lineStart = 0
			for (i, b) in buf.enumerated() where b == 0x0A {
				if i - lineStart > maxLine { return true }
				lineStart = i + 1
			}
			return buf.count - lineStart > maxLine
		}
	}

	/// Decodes bytes: BOMs first, then UTF-8, then the hint (e.g. windows-1250 for legacy projects).
	public static func load(_ data: Data, fallback: Charset = .windows1250) -> LoadedText {
		var charset = Charset.utf8
		var text: String
		if data.starts(with: [0xEF, 0xBB, 0xBF]) {
			charset = .utf8bom
			text = String(decoding: data.dropFirst(3), as: UTF8.self)
		} else if data.starts(with: [0xFE, 0xFF]) {
			charset = .utf16be
			text = String(data: data.dropFirst(2), encoding: .utf16BigEndian) ?? ""
		} else if data.starts(with: [0xFF, 0xFE]) {
			charset = .utf16le
			text = String(data: data.dropFirst(2), encoding: .utf16LittleEndian) ?? ""
		} else if let utf8 = String(data: data, encoding: .utf8) {
			text = utf8
		} else {
			charset = fallback
			text = String(data: data, encoding: fallback.encoding) ?? String(decoding: data, as: UTF8.self)
		}
		let normalized = normalizeLineEndings(text)
		var detected = detect(normalized.text)
		detected.lineEnding = normalized.dominant
		detected.mixedLineEndings = normalized.mixed
		text = normalized.text
		let lines = Set(text.split(separator: "\n", omittingEmptySubsequences: false))
		return LoadedText(text: text, charset: charset, detected: detected, originalLines: lines)
	}

	/// The first character of `text` that `charset` cannot store (saving would write "?"),
	/// or nil when it can store all of them.
	public static func firstUnencodable(_ text: String, charset: Charset) -> Character? {
		let encoding = charset.encoding
		guard !text.canBeConverted(to: encoding) else { return nil }
		return text.first { !String($0).canBeConverted(to: encoding) }
	}

	/// Encodes buffer text ("\n" only) for writing with the given settings.
	public static func save(_ text: String, settings: FormatSettings, originalLines: Set<Substring> = []) -> Data {
		var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
		switch settings.trimTrailingWhitespace {
		case .none: break
		case .all: lines = lines.map(trimmingTrailing)
		case .modifiedLines:
			lines = lines.map { originalLines.contains(Substring($0)) ? $0 : trimmingTrailing($0) }
		}
		var out = lines.joined(separator: "\n")
		if settings.insertFinalNewline, !out.isEmpty, !out.hasSuffix("\n") { out += "\n" }
		if settings.lineEnding != .lf { out = out.replacingOccurrences(of: "\n", with: settings.lineEnding.string) }
		var data = Data()
		if settings.charset == .utf8bom { data.append(contentsOf: [0xEF, 0xBB, 0xBF]) }
		if settings.charset == .utf16be { data.append(contentsOf: [0xFE, 0xFF]) }
		if settings.charset == .utf16le { data.append(contentsOf: [0xFF, 0xFE]) }
		// Characters the charset cannot store become "?"; the app asks first (firstUnencodable).
		data.append(out.data(using: settings.charset.encoding, allowLossyConversion: true) ?? Data(out.utf8))
		return data
	}

	/// Writes atomically without changing what the file is: a symbolic link keeps pointing at its
	/// target (the target is written) and the file keeps its permissions (executable scripts stay executable),
	/// owner and group (when the user may set them), ACL and extended attributes (tags, Finder info).
	public static func write(_ data: Data, to url: URL) throws {
		let target = url.resolvingSymlinksInPath()
		let fm = FileManager.default
		guard fm.fileExists(atPath: target.path) else {
			try data.write(to: target, options: .atomic)
			return
		}
		let temp = target.deletingLastPathComponent()
			.appendingPathComponent(".\(target.lastPathComponent).\(UUID().uuidString.prefix(8)).tmp")
		try data.write(to: temp)
		do {
			// Permissions, owner, ACL and extended attributes of the old file. A different owner
			// cannot be set without privileges; then everything else is copied and the user owns the file.
			if copyfile(target.path, temp.path, nil, copyfile_flags_t(COPYFILE_METADATA)) != 0 {
				guard copyfile(target.path, temp.path, nil, copyfile_flags_t(COPYFILE_XATTR | COPYFILE_ACL)) == 0 else {
					throw CocoaError(.fileWriteUnknown)
				}
				if let permissions = (try? fm.attributesOfItem(atPath: target.path))?[.posixPermissions] {
					try fm.setAttributes([.posixPermissions: permissions], ofItemAtPath: temp.path)
				}
			}
			utimes(temp.path, nil) // copyfile also copied the old modification time

			guard rename(temp.path, target.path) == 0 else {
				throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
			}
		} catch {
			try? fm.removeItem(at: temp)
			throw error
		}
	}

	static func trimmingTrailing(_ line: String) -> String {
		var s = Substring(line)
		while let last = s.last, last == " " || last == "\t" { s.removeLast() }
		return String(s)
	}

	/// Converts all line endings to "\n" and reports the most common original one.
	static func normalizeLineEndings(_ text: String) -> (text: String, dominant: LineEnding?, mixed: Bool) {
		var lf = 0, crlf = 0, cr = 0
		var out = [UInt8]()
		let bytes = Array(text.utf8)
		out.reserveCapacity(bytes.count)
		var i = 0
		while i < bytes.count {
			let b = bytes[i]
			if b == 0x0D {
				if i + 1 < bytes.count, bytes[i + 1] == 0x0A {
					crlf += 1
					i += 1
				} else {
					cr += 1
				}
				out.append(0x0A)
			} else {
				if b == 0x0A { lf += 1 }
				out.append(b)
			}
			i += 1
		}
		let counts: [(LineEnding, Int)] = [(.lf, lf), (.crlf, crlf), (.cr, cr)]
		let used = counts.filter { $0.1 > 0 }
		let dominant = used.max { $0.1 < $1.1 }?.0
		let normalized = (crlf + cr) == 0 ? text : String(decoding: out, as: UTF8.self)
		return (normalized, dominant, used.count > 1)
	}

	/// Guesses indentation from leading whitespace: tabs vs spaces, and the most common
	/// step between consecutive indented lines for spaces.
	public static func detect(_ text: String) -> DetectedFormat {
		var tabLines = 0, spaceLines = 0
		var steps: [Int: Int] = [:]
		var previous = 0
		var scanned = 0
		for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
			scanned += 1
			if scanned > 20_000 { break }
			guard let first = line.first, first == " " || first == "\t" else {
				if !line.allSatisfy(\.isWhitespace) { previous = 0 }
				continue
			}
			if line.allSatisfy(\.isWhitespace) { continue }
			if first == "\t" {
				tabLines += 1
				continue
			}
			let width = line.prefix { $0 == " " }.count
			// " * " continuation lines of doc comments do not indicate indentation
			if line.dropFirst(width).hasPrefix("*") { continue }
			spaceLines += 1
			let step = abs(width - previous)
			if step >= 2 && step <= 8 { steps[step, default: 0] += 1 }
			previous = width
		}
		var d = DetectedFormat()
		guard tabLines + spaceLines >= 3 else { return d }
		if tabLines > spaceLines {
			d.indentStyle = .tab
		} else {
			d.indentStyle = .space
			d.indentSize = steps.max { $0.value < $1.value || ($0.value == $1.value && $0.key > $1.key) }?.key
		}
		return d
	}
}
