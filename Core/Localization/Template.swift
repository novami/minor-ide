import Foundation

/// How a parameter is written: `{name}`, `{name, number}`, `{name, date:short}` …
nonisolated public enum ParameterFormat: Sendable, Equatable, CustomStringConvertible {
	case plain, number, percent, date(DateStyle), time, bytes

	public enum DateStyle: String, Sendable { case short, medium, long }

	init?(_ text: String) {
		switch text {
		case "": self = .plain
		case "number": self = .number
		case "percent": self = .percent
		case "time": self = .time
		case "bytes": self = .bytes
		case "date", "date:medium": self = .date(.medium)
		case "date:short": self = .date(.short)
		case "date:long": self = .date(.long)
		default: return nil
		}
	}

	public var description: String {
		switch self {
		case .plain: ""
		case .number: "number"
		case .percent: "percent"
		case .time: "time"
		case .bytes: "bytes"
		case .date(let style): "date:\(style.rawValue)"
		}
	}
}

/// A value passed to a message parameter.
nonisolated public enum L10nValue: Sendable {
	case text(String)
	case integer(Int)
	case decimal(Double)
	case date(Date)
}

/// A parsed message text: literal pieces and named parameters.
nonisolated public struct Template: Sendable, Equatable {
	public enum Segment: Sendable, Equatable {
		case literal(String)
		case parameter(String, ParameterFormat)
	}

	public let segments: [Segment]

	public var parameters: [(name: String, format: ParameterFormat)] {
		segments.compactMap { if case .parameter(let n, let f) = $0 { (n, f) } else { nil } }
	}

	public init(_ text: String) throws(TemplateError) {
		var segments: [Segment] = []
		var literal = ""
		var k = text.startIndex
		while k < text.endIndex {
			let c = text[k]
			let next = text.index(after: k)
			if c == "{" || c == "}" {
				if next < text.endIndex, text[next] == c { literal.append(c); k = text.index(after: next); continue }
				guard c == "{", let close = text[next...].firstIndex(of: "}") else { throw .unbalanced(text) }
				let inner = text[next..<close]
				let parts = inner.split(separator: ",", maxSplits: 1, omittingEmptySubsequences: false)
				let name = parts[0].trimmingCharacters(in: .whitespaces)
				let formatText = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : ""
				guard !name.isEmpty, name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }), name.first?.isNumber == false else {
					throw .invalidParameter(String(inner))
				}
				guard let format = ParameterFormat(formatText) else { throw .unknownFormat(formatText) }
				if !literal.isEmpty { segments.append(.literal(literal)); literal = "" }
				segments.append(.parameter(name, format))
				k = text.index(after: close)
				continue
			}
			literal.append(c)
			k = next
		}
		if !literal.isEmpty { segments.append(.literal(literal)) }
		self.segments = segments
	}

	/// A literal text that is never parsed (used when a template fails to parse at runtime).
	init(literal: String) { segments = [.literal(literal)] }

	func render(_ arguments: [String: L10nValue], locale: Locale) -> String {
		if segments.count == 1, case .literal(let s) = segments[0] { return s }
		var out = ""
		for segment in segments {
			switch segment {
			case .literal(let s): out += s
			case .parameter(let name, let format):
				guard let value = arguments[name] else { out += "{\(name)}"; continue }
				out += Self.format(value, format, locale)
			}
		}
		return out
	}

	static func format(_ value: L10nValue, _ format: ParameterFormat, _ locale: Locale) -> String {
		switch (value, format) {
		case (.text(let s), _): return s
		case (.integer(let n), .number): return n.formatted(.number.locale(locale))
		case (.integer(let n), .percent): return Double(n).formatted(.percent.locale(locale))
		case (.integer(let n), .bytes): return Int64(n).formatted(ByteCountFormatStyle(style: .file, locale: locale))
		case (.integer(let n), _): return String(n)
		case (.decimal(let d), .percent): return d.formatted(.percent.locale(locale))
		case (.decimal(let d), .bytes): return Int64(d).formatted(ByteCountFormatStyle(style: .file, locale: locale))
		case (.decimal(let d), _): return d.formatted(.number.locale(locale))
		case (.date(let d), .time): return d.formatted(Date.FormatStyle(date: .omitted, time: .shortened, locale: locale))
		case (.date(let d), .date(let style)):
			let date: Date.FormatStyle.DateStyle = switch style {
			case .short: .numeric
			case .medium: .abbreviated
			case .long: .long
			}
			return d.formatted(Date.FormatStyle(date: date, time: .omitted, locale: locale))
		case (.date(let d), _): return d.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened, locale: locale))
		}
	}
}

nonisolated public enum TemplateError: Error, Equatable, CustomStringConvertible {
	case unbalanced(String), invalidParameter(String), unknownFormat(String)
	public var description: String {
		switch self {
		case .unbalanced(let t): "unbalanced brace in \"\(t)\" (write {{ or }} for a literal brace)"
		case .invalidParameter(let p): "invalid parameter {\(p)}"
		case .unknownFormat(let f): "unknown parameter format \"\(f)\""
		}
	}
}
