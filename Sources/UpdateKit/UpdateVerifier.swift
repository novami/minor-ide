import CryptoKit
import Foundation

public enum UpdateVerifier {
	public enum Failure: Error, Equatable { case digestMismatch, badSignature, badKey }

	/// SHA-256 of a file, streamed so that large archives are not loaded into memory.
	public static func sha256(of file: URL) throws -> Data {
		let handle = try FileHandle(forReadingFrom: file)
		defer { try? handle.close() }
		var hasher = SHA256()
		while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
		return Data(hasher.finalize())
	}

	/// The bytes that are signed (MinorUpdate format v1). Binding the app ID and the version stops a
	/// signed archive of one app (the key is shared by several) or an older version being offered as another.
	public static func signedMessage(appID: String, version: String, sha256Hex: String) -> Data {
		Data("minorupdate-v1\n\(appID)\n\(version)\n\(sha256Hex.lowercased())".utf8)
	}

	/// Checks the archive against the feed: the digest must match and the Ed25519 signature
	/// over the message must verify with `publicKey` (raw 32 bytes, compiled into the app).
	public static func verify(file: URL, info: UpdateInfo, appID: String, publicKey: Data) throws {
		guard let key = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKey) else { throw Failure.badKey }
		let digest = try sha256(of: file)
		guard digest.map({ String(format: "%02x", $0) }).joined() == info.sha256.lowercased() else { throw Failure.digestMismatch }
		guard let signature = Data(base64Encoded: info.signature), key.isValidSignature(signature, for: signedMessage(appID: appID, version: info.version, sha256Hex: info.sha256)) else {
			throw Failure.badSignature
		}
	}
}
