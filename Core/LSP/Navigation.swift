import Foundation

/// A place in a file the server points to (plan 3.5).
nonisolated public struct Location: Sendable, Hashable {
	public var uri: String
	public var range: LSPRange

	public init(uri: String, range: LSPRange) {
		self.uri = uri
		self.range = range
	}

	/// A `Location`, or a `LocationLink` (its selection range: the name, not the whole declaration).
	public init?(_ json: JSONValue) {
		if let uri = json["uri"]?.stringValue, let range = LSPRange(json["range"]) {
			self.init(uri: uri, range: range)
		} else if let uri = json["targetUri"]?.stringValue,
		          let range = LSPRange(json["targetSelectionRange"]) ?? LSPRange(json["targetRange"]) {
			self.init(uri: uri, range: range)
		} else {
			return nil
		}
	}

	/// Result of `definition` and the like: null, one location, or an array of locations or links.
	public static func list(_ json: JSONValue?) -> [Location] {
		guard let json else { return [] }
		if let array = json.arrayValue { return array.compactMap(Location.init) }
		return Location(json).map { [$0] } ?? []
	}

	public var url: URL? {
		guard let url = URL(string: uri), url.isFileURL else { return nil }
		return url.standardizedFileURL
	}
}

/// What a jump asks the server for.
nonisolated public enum NavigationKind: Sendable, CaseIterable {
	case definition, implementation, typeDefinition, references

	public var method: String {
		switch self {
		case .definition: "textDocument/definition"
		case .implementation: "textDocument/implementation"
		case .typeDefinition: "textDocument/typeDefinition"
		case .references: "textDocument/references"
		}
	}

	var capability: String {
		switch self {
		case .definition: "definitionProvider"
		case .implementation: "implementationProvider"
		case .typeDefinition: "typeDefinitionProvider"
		case .references: "referencesProvider"
		}
	}
}

nonisolated extension LanguageServer {
	/// Whether the running server answers `kind` (the capability is true or an options object).
	public func supports(_ kind: NavigationKind) -> Bool {
		guard isRunning else { return false }
		switch capabilities[kind.capability] {
		case .bool(true), .object: return true
		default: return false
		}
	}

	/// Locations for the symbol at `offset` of an open document (`rope` is its current text).
	/// References leave out the declaration unless `includeDeclaration`.
	public func locations(_ kind: NavigationKind, uri: String, offset: Int, in rope: Rope,
	                      includeDeclaration: Bool = false) async throws -> [Location] {
		var params: [String: JSONValue] = [
			"textDocument": ["uri": .string(uri)],
			"position": rope.position(ofByte: offset, encoding: positionEncoding).json,
		]
		if kind == .references { params["context"] = ["includeDeclaration": .bool(includeDeclaration)] }
		return Location.list(try await request(kind.method, .object(params)))
	}
}
