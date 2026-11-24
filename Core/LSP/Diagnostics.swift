/// One problem from `textDocument/publishDiagnostics` (plan 3.7).
nonisolated public struct Diagnostic: Sendable, Equatable {
	/// Another place that explains the problem ("other declaration of x").
	public struct Related: Sendable, Equatable {
		public var location: Location
		public var message: String
	}

	public enum Severity: Int, Sendable, Comparable {
		case error = 1, warning, information, hint
		public static func < (a: Severity, b: Severity) -> Bool { a.rawValue < b.rawValue }
	}

	public var range: LSPRange
	public var severity: Severity
	public var message: String
	public var source: String?
	public var code: String?
	/// Where the code is explained (`codeDescription.href`).
	public var href: String?
	public var related: [Related]
	/// Unused code (drawn faded by some editors).
	public var unnecessary: Bool
	public var deprecated: Bool
	/// The diagnostic as sent; code actions (quick fixes) send it back.
	public var json: JSONValue

	public init?(_ json: JSONValue) {
		guard let range = LSPRange(json["range"]), let message = json["message"]?.stringValue else { return nil }
		self.range = range
		self.message = message
		severity = json["severity"]?.doubleValue.flatMap { Severity(rawValue: Int($0)) } ?? .error
		source = json["source"]?.stringValue
		switch json["code"] {
		case .string(let s)?: code = s
		case .number(let n)?: code = String(Int(n))
		default: code = nil
		}
		href = json["codeDescription"]?["href"]?.stringValue
		related = (json["relatedInformation"]?.arrayValue ?? []).compactMap { r in
			guard let location = Location(r["location"] ?? .null), let message = r["message"]?.stringValue else { return nil }
			return Related(location: location, message: message)
		}
		let tags = (json["tags"]?.arrayValue ?? []).compactMap(\.doubleValue)
		unnecessary = tags.contains(1)
		deprecated = tags.contains(2)
		self.json = json
	}
}

/// The diagnostics of one file. `ranges` are byte ranges in the text of `version` (the version
/// the server diagnosed, or the latest sent when it gave none); nil when the file is not open.
nonisolated public struct PublishedDiagnostics: Sendable {
	public var uri: String
	public var version: Int?
	public var diagnostics: [Diagnostic]
	public var ranges: [Range<Int>]?

	public init?(_ params: JSONValue) {
		guard let uri = params["uri"]?.stringValue else { return nil }
		self.uri = uri
		version = params["version"]?.doubleValue.map { Int($0) }
		diagnostics = (params["diagnostics"]?.arrayValue ?? []).compactMap(Diagnostic.init)
	}
}
