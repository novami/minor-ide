import Foundation

/// Dotted numeric version ("1.2.10"); missing parts count as 0.
public struct AppVersion: Comparable, Sendable, CustomStringConvertible {
	public let parts: [Int]

	public init?(_ text: String) {
		let trimmed = text.hasPrefix("v") ? String(text.dropFirst()) : text
		let numbers = trimmed.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
		guard !numbers.isEmpty, !numbers.contains(nil) else { return nil }
		parts = numbers.compactMap { $0 }
	}

	public var description: String { parts.map(String.init).joined(separator: ".") }

	public static func < (a: AppVersion, b: AppVersion) -> Bool {
		for i in 0..<max(a.parts.count, b.parts.count) {
			let x = i < a.parts.count ? a.parts[i] : 0
			let y = i < b.parts.count ? b.parts[i] : 0
			if x != y { return x < y }
		}
		return false
	}

	public static func == (a: AppVersion, b: AppVersion) -> Bool { !(a < b) && !(b < a) }
}

/// One release in the update feed (JSON served over HTTPS).
public struct UpdateInfo: Sendable, Equatable, Decodable {
	public let version: String
	public let url: URL
	/// SHA-256 of the archive, lowercase hex.
	public let sha256: String
	/// Ed25519 signature (base64) over `UpdateVerifier.signedMessage`.
	public let signature: String
	public let notes: String?
	public let minimumSystemVersion: String?

	public enum FeedError: Error, Equatable { case invalid, insecureURL }

	/// Decodes and validates a feed; the archive URL must be HTTPS.
	public static func parse(_ data: Data) throws -> UpdateInfo {
		guard let info = try? JSONDecoder().decode(UpdateInfo.self, from: data),
		      AppVersion(info.version) != nil,
		      info.sha256.count == 64, info.sha256.allSatisfy(\.isHexDigit) else { throw FeedError.invalid }
		guard info.url.scheme?.lowercased() == "https", info.url.host?.isEmpty == false else { throw FeedError.insecureURL }
		return info
	}
}
