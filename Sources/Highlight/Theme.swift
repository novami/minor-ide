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

	public static let light = try! Theme(json: """
		{"name": "Light", "colors": {
			"keyword": "#9C27B0", "type": "#00796B", "function": "#3949AB", "string": "#C62828",
			"escape": "#E65100", "number": "#1565C0", "constant": "#6A1B9A", "comment": "#6D7A86",
			"variable": "#00838F", "property": "#2E7D32", "tag": "#1565C0", "attribute": "#8D6E00",
			"macro": "#AD1457", "invalid": "#D32F2F"}}
		""")

	public static let dark = try! Theme(json: """
		{"name": "Dark", "colors": {
			"keyword": "#E58BE0", "type": "#6FD3C4", "function": "#8FB4FF", "string": "#FF8A80",
			"escape": "#FFB86C", "number": "#9CC8FF", "constant": "#D7A6FF", "comment": "#8A96A3",
			"variable": "#7FDBE6", "property": "#A5D6A7", "tag": "#82AAFF", "attribute": "#E6C07B",
			"macro": "#F48FB1", "invalid": "#FF6B6B"}}
		""")
}
