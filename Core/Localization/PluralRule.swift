import Foundation

/// CLDR plural categories in their canonical order.
nonisolated public enum PluralCategory: String, CaseIterable, Sendable {
	case zero, one, two, few, many, other
}

/// Plural operands of a number (CLDR): n absolute value, i integer digits, v count of visible
/// fraction digits, f visible fraction digits, t visible fraction digits without trailing zeros.
nonisolated public struct PluralOperands: Sendable, Equatable {
	public var n: Double
	public var i: Int
	public var v: Int
	public var f: Int
	public var t: Int

	public init(_ value: Int) {
		n = Double(value.magnitude)
		i = Int(value.magnitude)
		v = 0; f = 0; t = 0
	}

	/// A decimal written as text, such as "1.50" (v = 2, f = 50, t = 5).
	public init?(decimal text: String) {
		var digits = text.hasPrefix("-") ? String(text.dropFirst()) : text
		if digits.isEmpty { return nil }
		var fraction = ""
		if let dot = digits.firstIndex(of: ".") {
			fraction = String(digits[digits.index(after: dot)...])
			digits = String(digits[..<dot])
		}
		guard !digits.isEmpty, digits.allSatisfy(\.isASCIIDigit), fraction.allSatisfy(\.isASCIIDigit),
		      let whole = Int(digits), let value = Double(digits + "." + (fraction.isEmpty ? "0" : fraction)) else { return nil }
		n = value
		i = whole
		v = fraction.count
		f = Int(fraction.prefix(18)) ?? 0
		let trimmed = fraction.reversed().drop { $0 == "0" }
		t = Int(String(trimmed.reversed()).prefix(18)) ?? 0
	}

	public init(_ value: Double) {
		var text = String(value.magnitude)
		if text.contains("e") || text.contains("n") || text.contains("i") { text = String(format: "%.6f", value.magnitude) }
		if text.hasSuffix(".0") { text.removeLast(2) }
		self = PluralOperands(decimal: text) ?? PluralOperands(0)
	}
}

nonisolated private extension Character {
	var isASCIIDigit: Bool { isASCII && isNumber }
}

/// One CLDR plural rule condition, such as `i = 2..4 and v = 0`. Sample lists after `@` are ignored.
nonisolated public struct PluralRule: Sendable {
	fileprivate enum Operand: Character { case n = "n", i = "i", v = "v", f = "f", t = "t", e = "e", c = "c" }
	fileprivate struct Relation: Sendable {
		var operand: Operand
		var modulo: Int?
		var negated: Bool
		var ranges: [ClosedRange<Int>]
	}

	/// Alternatives joined by `or`; each holds relations joined by `and`.
	private let conditions: [[Relation]]

	public init(_ source: String) throws(PluralRuleError) {
		let text = source.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
		var parser = Parser(tokens: try Self.tokenize(text))
		conditions = try parser.parse()
	}

	public func matches(_ x: PluralOperands) -> Bool {
		conditions.contains { relations in relations.allSatisfy { Self.holds($0, x) } }
	}

	private static func holds(_ r: Relation, _ x: PluralOperands) -> Bool {
		let value: Double
		switch r.operand {
		case .n: value = x.n
		case .i: value = Double(x.i)
		case .v: value = Double(x.v)
		case .f: value = Double(x.f)
		case .t: value = Double(x.t)
		case .e, .c: value = 0
		}
		var operand = value
		if let m = r.modulo, m != 0 { operand = value.truncatingRemainder(dividingBy: Double(m)) }
		let inside = operand == operand.rounded() && r.ranges.contains { Double($0.lowerBound) <= operand && operand <= Double($0.upperBound) }
		return inside != r.negated
	}

	fileprivate enum Token: Equatable { case word(String), number(Int), equals, notEquals, percent, comma, dots }

	private static func tokenize(_ text: String) throws(PluralRuleError) -> [Token] {
		var tokens: [Token] = []
		let chars = Array(text)
		var k = 0
		while k < chars.count {
			let c = chars[k]
			if c.isWhitespace { k += 1; continue }
			if c.isASCIIDigit {
				var end = k
				while end < chars.count, chars[end].isASCIIDigit { end += 1 }
				guard let number = Int(String(chars[k..<end])) else { throw .invalid(text) }
				tokens.append(.number(number)); k = end; continue
			}
			if c.isLetter {
				var end = k
				while end < chars.count, chars[end].isLetter { end += 1 }
				tokens.append(.word(String(chars[k..<end]))); k = end; continue
			}
			switch c {
			case "=": tokens.append(.equals); k += 1
			case "!" where k + 1 < chars.count && chars[k + 1] == "=": tokens.append(.notEquals); k += 2
			case "%": tokens.append(.percent); k += 1
			case ",": tokens.append(.comma); k += 1
			case "." where k + 1 < chars.count && chars[k + 1] == ".": tokens.append(.dots); k += 2
			default: throw .invalid(text)
			}
		}
		return tokens
	}

	private struct Parser {
		let tokens: [Token]
		var at = 0

		mutating func parse() throws(PluralRuleError) -> [[Relation]] {
			if tokens.isEmpty { return [] }
			var result = [try andCondition()]
			while accept(.word("or")) { result.append(try andCondition()) }
			guard at == tokens.count else { throw .invalid(describe()) }
			return result
		}

		mutating func andCondition() throws(PluralRuleError) -> [Relation] {
			var result = [try relation()]
			while accept(.word("and")) { result.append(try relation()) }
			return result
		}

		mutating func relation() throws(PluralRuleError) -> Relation {
			guard at < tokens.count, case .word(let name) = tokens[at], name.count == 1,
			      let first = name.first, let operand = Operand(rawValue: first) else { throw .invalid(describe()) }
			at += 1
			var modulo: Int?
			if accept(.percent) { modulo = try number() }
			let negated: Bool
			if accept(.equals) { negated = false }
			else if accept(.notEquals) { negated = true }
			else if accept(.word("is")) { negated = accept(.word("not")) }
			else if accept(.word("not")) { guard accept(.word("in")) else { throw .invalid(describe()) }; negated = true }
			else if accept(.word("in")) { negated = false }
			else { throw .invalid(describe()) }
			var ranges = [try range()]
			while accept(.comma) { ranges.append(try range()) }
			return Relation(operand: operand, modulo: modulo, negated: negated, ranges: ranges)
		}

		mutating func range() throws(PluralRuleError) -> ClosedRange<Int> {
			let low = try number()
			guard accept(.dots) else { return low...low }
			let high = try number()
			guard low <= high else { throw .invalid(describe()) }
			return low...high
		}

		mutating func number() throws(PluralRuleError) -> Int {
			guard at < tokens.count, case .number(let value) = tokens[at] else { throw .invalid(describe()) }
			at += 1
			return value
		}

		mutating func accept(_ token: Token) -> Bool {
			guard at < tokens.count, tokens[at] == token else { return false }
			at += 1
			return true
		}

		func describe() -> String { "token \(at + 1)" }
	}
}

nonisolated public enum PluralRuleError: Error, Equatable, CustomStringConvertible {
	case invalid(String)
	public var description: String {
		switch self {
		case .invalid(let place): "invalid plural rule near \(place)"
		}
	}
}

/// The plural rules of one language: the category for a number.
nonisolated public struct PluralRules: Sendable {
	public let rules: [(PluralCategory, PluralRule)]

	public init(_ source: [String: String]) throws(PluralRuleError) {
		var rules: [(PluralCategory, PluralRule)] = []
		for category in PluralCategory.allCases where category != .other {
			if let text = source[category.rawValue] { rules.append((category, try PluralRule(text))) }
		}
		self.rules = rules
	}

	init() { rules = [] }

	public func category(_ x: PluralOperands) -> PluralCategory {
		rules.first { $0.1.matches(x) }?.0 ?? .other
	}
}
