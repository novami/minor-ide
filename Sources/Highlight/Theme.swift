import Foundation

/// Token colours as JSON: {"name": …, "colors": {"keyword": "#RRGGBB", …}}. Kinds without a
/// colour use the text colour. Built-in light and dark themes follow the system appearance.
public struct Theme: Sendable, Codable, Equatable {
	public var name: String
	public var colors: [String: String]

	public init(json: String) throws {
		self = try JSONDecoder().decode(Theme.self, from: Data(json.utf8))
	}

	/// RGBA components (0…1) of a kind's colour, nil for the text colour.
	public func rgba(_ kind: TokenKind) -> (Double, Double, Double, Double)? {
		guard let hex = colors[kind.name], hex.hasPrefix("#") else { return nil }
		let digits = hex.dropFirst()
		guard digits.count == 6 || digits.count == 8, let value = UInt64(digits, radix: 16) else { return nil }
		let v = digits.count == 6 ? value << 8 | 0xFF : value
		return (Double(v >> 24 & 0xFF) / 255, Double(v >> 16 & 0xFF) / 255, Double(v >> 8 & 0xFF) / 255, Double(v & 0xFF) / 255)
	}

	/// The kind's colour moved towards black or white (away from the background) until it
	/// has at least `ratio` WCAG contrast against `background`; for Increase Contrast.
	public func rgba(_ kind: TokenKind, contrast ratio: Double, against background: (Double, Double, Double)) -> (Double, Double, Double, Double)? {
		guard let c = rgba(kind) else { return nil }
		let bg = Self.luminance(background)
		let target = bg > 0.18 ? 0.0 : 1.0
		var t = 0.0, color = c
		while Self.contrast(Self.luminance((color.0, color.1, color.2)), bg) < ratio, t < 1 {
			t = min(1, t + 0.05)
			color = (c.0 + (target - c.0) * t, c.1 + (target - c.1) * t, c.2 + (target - c.2) * t, c.3)
		}
		return color
	}

	/// WCAG relative luminance of an sRGB colour.
	public static func luminance(_ c: (Double, Double, Double)) -> Double {
		func linear(_ v: Double) -> Double { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
		return 0.2126 * linear(c.0) + 0.7152 * linear(c.1) + 0.0722 * linear(c.2)
	}

	public static func contrast(_ a: Double, _ b: Double) -> Double {
		(max(a, b) + 0.05) / (min(a, b) + 0.05)
	}

	// A constant, valid JSON checked by the tests: a failure is a programming error.
	// swiftlint:disable:next force_try
	public static let light = try! Theme(json: """
		{"name": "Light", "colors": {
			"keyword": "#9C27B0", "type": "#00796B", "function": "#3949AB", "string": "#C62828",
			"escape": "#E65100", "number": "#1565C0", "constant": "#6A1B9A", "comment": "#6D7A86",
			"variable": "#00838F", "property": "#2E7D32", "tag": "#1565C0", "attribute": "#8D6E00",
			"macro": "#AD1457", "invalid": "#D32F2F"}}
		""")

	// swiftlint:disable:next force_try
	public static let dark = try! Theme(json: """
		{"name": "Dark", "colors": {
			"keyword": "#E58BE0", "type": "#6FD3C4", "function": "#8FB4FF", "string": "#FF8A80",
			"escape": "#FFB86C", "number": "#9CC8FF", "constant": "#D7A6FF", "comment": "#8A96A3",
			"variable": "#7FDBE6", "property": "#A5D6A7", "tag": "#82AAFF", "attribute": "#E6C07B",
			"macro": "#F48FB1", "invalid": "#FF6B6B"}}
		""")
}
