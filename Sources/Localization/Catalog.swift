import Foundation

/// One message: a text, plural forms, and optional named variants.
public struct Message: Sendable {
	public var text: Template?
	public var plural: [PluralCategory: Template] = [:]
	public var variants: [String: Template] = [:]
	/// Note for translators (only in the source language).
	public var note: String?
	public var line = 0

	public var isPlural: Bool { !plural.isEmpty }

	/// All templates of the message (text, plural forms, variants).
	public var templates: [Template] { [text].compactMap { $0 } + plural.values + variants.values }
}

/// The `$meta` object of a language file.
public struct CatalogMeta: Sendable {
	public var locale: String
	public var name: String
	public var englishName: String
	public var fallback: String?
	public var plural: [String: String]
}

/// One language file, flattened to dotted key paths.
public struct Catalog: Sendable {
	public let meta: CatalogMeta
	public let messages: [String: Message]
	public let pluralRules: PluralRules
	/// Problems found while reading (bad templates, unknown shapes); the validator reports them.
	public let problems: [String]

	public init(data: Data) throws {
		let parsed = try JSONTreeParser.parse(data)
		try self.init(tree: parsed.tree)
	}

	public init(tree: JSONTree) throws {
		guard case .object(let members) = tree else { throw CatalogError.notAnObject }
		guard let metaTree = tree["$meta"], let locale = metaTree["locale"]?.string else { throw CatalogError.missingMeta("locale") }
		var plural: [String: String] = [:]
		if case .object(let rules)? = metaTree["plural"] {
			for rule in rules { plural[rule.key] = rule.value.string ?? "" }
		}
		meta = CatalogMeta(locale: locale, name: metaTree["name"]?.string ?? "", englishName: metaTree["englishName"]?.string ?? "",
		                   fallback: metaTree["fallback"]?.string, plural: plural)
		pluralRules = try PluralRules(plural)
		var messages: [String: Message] = [:]
		var problems: [String] = []
		for member in members where member.key != "$meta" {
			Self.collect(member, prefix: "", into: &messages, problems: &problems)
		}
		self.messages = messages
		self.problems = problems
	}

	/// A catalog without messages.
	public init(empty locale: String) {
		meta = CatalogMeta(locale: locale, name: "", englishName: "", fallback: nil, plural: [:])
		messages = [:]
		pluralRules = PluralRules()
		problems = []
	}

	private static let pluralKeys = Set(PluralCategory.allCases.map(\.rawValue))

	private static func collect(_ member: JSONTree.Member, prefix: String, into messages: inout [String: Message], problems: inout [String]) {
		let key = prefix.isEmpty ? member.key : prefix + "." + member.key
		func template(_ text: String) -> Template {
			do { return try Template(text) } catch {
				problems.append("\(key) (line \(member.line)): \(error)")
				return Template(literal: text)
			}
		}
		switch member.value {
		case .string(let s):
			messages[key] = Message(text: template(s), line: member.line)
		case .object(let children):
			let names = Set(children.map(\.key))
			let isPlural = names.contains("other") && names.subtracting(["note"]).isSubset(of: pluralKeys)
			if names.contains("text") || isPlural {
				var message = Message(line: member.line)
				for child in children {
					switch (child.key, child.value) {
					case ("note", .string(let s)): message.note = s
					case ("text", .string(let s)): message.text = template(s)
					case ("variants", .object(let variants)):
						for v in variants {
							if let s = v.value.string { message.variants[v.key] = template(s) }
							else { problems.append("\(key).variants.\(v.key) (line \(v.line)): a variant must be a string") }
						}
					case (let name, .string(let s)) where isPlural:
						if let category = PluralCategory(rawValue: name) { message.plural[category] = template(s) }
					default: problems.append("\(key).\(child.key) (line \(child.line)): unexpected value")
					}
				}
				messages[key] = message
			} else {
				if children.isEmpty { problems.append("\(key) (line \(member.line)): empty namespace") }
				for child in children { collect(child, prefix: key, into: &messages, problems: &problems) }
			}
		default:
			problems.append("\(key) (line \(member.line)): a message must be a string or an object")
		}
	}
}

public enum CatalogError: Error, CustomStringConvertible {
	case notAnObject, missingMeta(String)
	public var description: String {
		switch self {
		case .notAnObject: "a language file must be a JSON object"
		case .missingMeta(let field): "$meta.\(field) is missing"
		}
	}
}
