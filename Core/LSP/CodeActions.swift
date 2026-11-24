import Foundation

/// Changes to files from rename, a code action or `workspace/applyEdit` (plan 3.7).
nonisolated public struct WorkspaceEdit: Sendable {
	public struct FileEdit: Sendable {
		public var uri: String
		/// The document version the edits were computed for (nil: any).
		public var version: Int?
		public var edits: [TextEdit]

		public var url: URL? {
			guard let url = URL(string: uri), url.isFileURL else { return nil }
			return url.standardizedFileURL
		}
	}

	public var files: [FileEdit]
	/// It creates, renames or deletes files, which the client does not do.
	public var hasFileOperations: Bool

	public init?(_ json: JSONValue?) {
		guard let json, case .object = json else { return nil }
		var files: [FileEdit] = []
		var operations = false
		if let changes = json["documentChanges"]?.arrayValue {
			for change in changes {
				guard let doc = change["textDocument"], let uri = doc["uri"]?.stringValue else {
					operations = true
					continue
				}
				let edits = (change["edits"]?.arrayValue ?? []).compactMap { TextEdit($0) }
				files.append(FileEdit(uri: uri, version: doc["version"]?.doubleValue.map { Int($0) }, edits: edits))
			}
		} else if case .object(let changes)? = json["changes"] {
			for (uri, edits) in changes.sorted(by: { $0.key < $1.key }) {
				files.append(FileEdit(uri: uri, version: nil, edits: (edits.arrayValue ?? []).compactMap { TextEdit($0) }))
			}
		}
		// Edits of one file may come in several entries.
		var merged: [FileEdit] = []
		for f in files where !f.edits.isEmpty {
			if let i = merged.firstIndex(where: { $0.uri == f.uri }) { merged[i].edits += f.edits } else { merged.append(f) }
		}
		self.files = merged
		hasFileOperations = operations
	}

	public var isEmpty: Bool { files.isEmpty }
	public var editCount: Int { files.reduce(0) { $0 + $1.edits.count } }
}

nonisolated extension Rope {
	/// Byte replacements of LSP text edits, in order; nil when edits overlap.
	public func replacements(_ edits: [TextEdit], encoding: PositionEncoding) -> [(Range<Int>, String)]? {
		// Insertions go before a replacement starting at the same place; insertions at one
		// place keep the server's order (the spec asks for that).
		let list = edits.enumerated().map { (i, e) in (range(of: e.range, encoding: encoding), e.newText, i) }
			.sorted { ($0.0.lowerBound, $0.0.upperBound, $0.2) < ($1.0.lowerBound, $1.0.upperBound, $1.2) }
		for (a, b) in zip(list, list.dropFirst()) where b.0.lowerBound < a.0.upperBound { return nil }
		return list.map { ($0.0, $0.1) }
	}
}

/// One entry of `textDocument/codeAction`: a fix or refactoring with an edit, a command or both.
nonisolated public struct CodeAction: Sendable {
	public var title: String
	/// "quickfix", "refactor.extract", "source.organizeImports"… (empty when not given).
	public var kind: String
	public var isPreferred: Bool
	/// Why it cannot be applied now (shown greyed out).
	public var disabledReason: String?
	public var edit: WorkspaceEdit?
	/// `Command`: run after the edit (`workspace/executeCommand`).
	public var command: JSONValue?
	/// The action as sent; `codeAction/resolve` takes it back.
	public var json: JSONValue

	public init?(_ json: JSONValue) {
		guard let title = json["title"]?.stringValue else { return nil }
		self.title = title
		self.json = json
		if let name = json["command"]?.stringValue {
			// A bare Command.
			kind = ""
			isPreferred = false
			disabledReason = nil
			edit = nil
			command = ["title": .string(title), "command": .string(name), "arguments": json["arguments"] ?? []]
			return
		}
		kind = json["kind"]?.stringValue ?? ""
		isPreferred = json["isPreferred"] == .bool(true)
		disabledReason = json["disabled"]?["reason"]?.stringValue
		edit = WorkspaceEdit(json["edit"])
		command = json["command"]
	}

	public var isQuickFix: Bool { kind == "quickfix" || kind.hasPrefix("quickfix.") }
}

nonisolated extension LanguageServer {
	private func provides(_ capability: String) -> Bool {
		guard isRunning else { return false }
		switch capabilities[capability] {
		case .bool(true), .object: return true
		default: return false
		}
	}

	public var supportsCodeActions: Bool { provides("codeActionProvider") }
	public var supportsRename: Bool { provides("renameProvider") }

	/// Code actions for `range` of an open document; `diagnostics` are the LSP diagnostics
	/// there (with ranges in the current text). Disabled ones come last.
	public func codeActions(uri: String, range: Range<Int>, in rope: Rope, diagnostics: [JSONValue]) async throws -> [CodeAction] {
		let params: JSONValue = [
			"textDocument": ["uri": .string(uri)],
			"range": rope.lspRange(range, encoding: positionEncoding).json,
			"context": ["diagnostics": .array(diagnostics), "triggerKind": 1],
		]
		let actions = (try await request("textDocument/codeAction", params).arrayValue ?? []).compactMap(CodeAction.init)
		return actions.filter { $0.disabledReason == nil } + actions.filter { $0.disabledReason != nil }
	}

	/// Fills in the edit of an action sent without one (`codeAction/resolve`), when the server can.
	public func resolve(_ action: CodeAction) async throws -> CodeAction {
		guard action.edit == nil, action.command == nil || action.json["data"] != nil,
		      capabilities["codeActionProvider"]?["resolveProvider"] == .bool(true),
		      let resolved = CodeAction(try await request("codeAction/resolve", action.json)) else { return action }
		return resolved
	}

	/// Runs a command (`workspace/executeCommand`); its edits come back as `workspace/applyEdit`.
	public func execute(_ command: JSONValue) async throws {
		guard let name = command["command"]?.stringValue else { return }
		_ = try await request("workspace/executeCommand", ["command": .string(name), "arguments": command["arguments"] ?? []])
	}

	/// The symbol at `offset` that can be renamed and its current name; nil when there is none.
	/// Without `prepareRename` the word at `offset`.
	public func prepareRename(uri: String, offset: Int, in rope: Rope) async throws -> (range: Range<Int>, name: String)? {
		let word = rope.wordRange(at: offset)
		guard capabilities["renameProvider"]?["prepareProvider"] == .bool(true) else {
			return word.isEmpty ? nil : (word, rope.string(in: word))
		}
		let result = try await request("textDocument/prepareRename", [
			"textDocument": ["uri": .string(uri)],
			"position": rope.position(ofByte: offset, encoding: positionEncoding).json,
		])
		if let range = LSPRange(result) {
			let r = rope.range(of: range, encoding: positionEncoding)
			return (r, rope.string(in: r))
		}
		if let range = LSPRange(result["range"]) {
			let r = rope.range(of: range, encoding: positionEncoding)
			return (r, result["placeholder"]?.stringValue ?? rope.string(in: r))
		}
		if result["defaultBehavior"] == .bool(true), !word.isEmpty { return (word, rope.string(in: word)) }
		return nil
	}

	/// The edits renaming the symbol at `offset` to `newName`.
	public func rename(uri: String, offset: Int, in rope: Rope, to newName: String) async throws -> WorkspaceEdit? {
		WorkspaceEdit(try await request("textDocument/rename", [
			"textDocument": ["uri": .string(uri)],
			"position": rope.position(ofByte: offset, encoding: positionEncoding).json,
			"newName": .string(newName),
		]))
	}
}

nonisolated extension Rope {
	/// The changed lines as they will read after `replacements` (sorted, not overlapping),
	/// each with the new text marked (byte ranges in `text`); long lines are cut around it.
	public func previewLines(_ replacements: [(Range<Int>, String)]) -> [FileSearchLine] {
		var lines: [FileSearchLine] = []
		var i = 0
		while i < replacements.count {
			let line = line(containing: replacements[i].0.lowerBound)
			var full = lineRange(line)
			while full.upperBound > full.lowerBound, [0x0A, 0x0D].contains(byte(at: full.upperBound - 1)) {
				full = full.lowerBound..<(full.upperBound - 1)
			}
			var text = [UInt8](), marked: [Range<Int>] = []
			var at = full.lowerBound
			while i < replacements.count, replacements[i].0.lowerBound <= full.upperBound,
			      self.line(containing: replacements[i].0.lowerBound) == line {
				let (range, new) = replacements[i]
				text += Array(string(in: at..<range.lowerBound).utf8)
				let start = text.count
				// A multi-line replacement shows its first line.
				text += Array((new.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first ?? "").utf8)
				marked.append(start..<text.count)
				at = min(max(range.upperBound, at), full.upperBound)
				i += 1
			}
			text += Array(string(in: at..<max(at, full.upperBound)).utf8)
			// Cut around the marks: 60 bytes before the first, 160 after the last.
			var from = max(0, (marked.first?.lowerBound ?? 0) - 60)
			var to = min(text.count, (marked.last?.upperBound ?? 0) + 160)
			while from > 0, text[from] & 0xC0 == 0x80 { from -= 1 }
			while to < text.count, text[to] & 0xC0 == 0x80 { to += 1 }
			let cut = String(decoding: text[from..<to], as: UTF8.self)
			lines.append(FileSearchLine(line: line, column: from, text: cut,
			                            ranges: marked.map { ($0.lowerBound - from)..<($0.upperBound - from) }))
		}
		return lines
	}
}
