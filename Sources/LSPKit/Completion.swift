import MinorCore
import TextEngine

public struct TextEdit: Sendable, Equatable {
	public var range: LSPRange
	public var newText: String

	public init(range: LSPRange, newText: String) {
		self.range = range
		self.newText = newText
	}

	public init?(_ json: JSONValue?) {
		guard let range = LSPRange(json?["range"]), let text = json?["newText"]?.stringValue else { return nil }
		self.init(range: range, newText: text)
	}
}

/// One proposal of `textDocument/completion` (plan 3.4).
public struct CompletionItem: Sendable {
	public var label: String
	/// `CompletionItemKind` (1 text … 25 type parameter).
	public var kind: Int
	public var detail: String?
	/// `labelDetails`: shown after the label (signature, package).
	public var labelDetail: String?
	public var documentation: String?
	public var sortText: String
	public var filterText: String
	public var insertText: String
	public var isSnippet: Bool
	/// Range the text replaces (the insert range of an insert/replace edit); nil means the word before the caret.
	public var range: LSPRange?
	/// Edits elsewhere, like an import the item needs.
	public var additionalTextEdits: [TextEdit]
	public var deprecated: Bool
	public var preselect: Bool
	/// Set after `completionItem/resolve` (or when the server has nothing to resolve).
	public var resolved: Bool
	/// The item as the server sent it, for `completionItem/resolve`.
	public var raw: JSONValue

	/// `defaults`: the list's `itemDefaults` (edit range, insert text format).
	public init?(_ json: JSONValue, defaults: JSONValue? = nil) {
		guard let label = json["label"]?.stringValue else { return nil }
		self.label = label
		kind = json["kind"]?.doubleValue.map { Int($0) } ?? 1
		detail = json["detail"]?.stringValue
		let details = [json["labelDetails"]?["detail"]?.stringValue, json["labelDetails"]?["description"]?.stringValue]
			.compactMap { $0 }.filter { !$0.isEmpty }
		labelDetail = details.isEmpty ? nil : details.joined(separator: " ")
		documentation = Self.markup(json["documentation"])
		sortText = json["sortText"]?.stringValue ?? label
		filterText = json["filterText"]?.stringValue ?? label
		let edit = json["textEdit"]
		let format = json["insertTextFormat"]?.doubleValue ?? defaults?["insertTextFormat"]?.doubleValue
		isSnippet = format == 2
		insertText = edit?["newText"]?.stringValue ?? json["insertText"]?.stringValue ?? label
		let defaultRange = defaults?["editRange"]
		range = LSPRange(edit?["range"]) ?? LSPRange(edit?["insert"])
			?? LSPRange(defaultRange) ?? LSPRange(defaultRange?["insert"])
		additionalTextEdits = json["additionalTextEdits"]?.arrayValue?.compactMap { TextEdit($0) } ?? []
		deprecated = json["deprecated"] == .bool(true)
			|| (json["tags"]?.arrayValue?.contains(.number(1)) ?? false)
		preselect = json["preselect"] == .bool(true)
		resolved = false
		raw = json
	}

	/// Takes what `completionItem/resolve` filled in.
	public mutating func merge(resolved json: JSONValue) {
		if let d = json["detail"]?.stringValue { detail = d }
		if let doc = Self.markup(json["documentation"]) { documentation = doc }
		if let edits = json["additionalTextEdits"]?.arrayValue { additionalTextEdits = edits.compactMap { TextEdit($0) } }
		resolved = true
	}

	/// The text to insert, with its tab stops.
	public var snippet: Snippet { isSnippet ? Snippet(parsing: insertText) : Snippet(text: insertText) }

	static func markup(_ json: JSONValue?) -> String? {
		let text = json?.stringValue ?? json?["value"]?.stringValue
		return text?.isEmpty == false ? text : nil
	}
}

public struct CompletionList: Sendable {
	public var isIncomplete: Bool
	public var items: [CompletionItem]

	/// Accepts a `CompletionList` or a bare array of items (and null).
	public init(_ json: JSONValue) {
		if let array = json.arrayValue {
			isIncomplete = false
			items = array.compactMap { CompletionItem($0) }
		} else {
			isIncomplete = json["isIncomplete"] == .bool(true)
			let defaults = json["itemDefaults"]
			items = json["items"]?.arrayValue?.compactMap { CompletionItem($0, defaults: defaults) } ?? []
		}
	}

	/// Indices of the items matching the typed `prefix`, best first: fuzzy score on the filter
	/// text, then the server's sort text. An empty prefix keeps everything in the server's order.
	public func filtered(by prefix: String) -> [Int] {
		let query = FuzzyQuery(prefix)
		var scratch = FuzzyQuery.Scratch()
		var scored: [(index: Int, score: Int)] = []
		for (i, item) in items.enumerated() {
			if query.isEmpty { scored.append((i, 0)); continue }
			if let s = query.score(FuzzyPath(item.filterText), &scratch) { scored.append((i, s)) }
		}
		scored.sort { a, b in
			if a.score != b.score { return a.score > b.score }
			let x = items[a.index], y = items[b.index]
			if x.sortText != y.sortText { return x.sortText < y.sortText }
			return a.index < b.index
		}
		return scored.map(\.index)
	}
}

/// Moves a byte offset the server computed on the text at the request (caret at `old`) to the
/// current text (caret at `now`), when everything typed since went in at the caret: text before
/// both carets is unchanged, text after the old caret moved with it. `isEnd`: an end at the old
/// caret follows the caret (the replaced word grew with the typing).
public func completionOffset(_ offset: Int, oldCaret old: Int, caret now: Int, isEnd: Bool) -> Int {
	if offset < old || (offset == old && !isEnd) { return min(offset, now) }
	return offset + now - old
}
