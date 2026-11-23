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

	/// Checks the archive against the feed: the digest must match and the Ed25519 signature
	/// over the digest must verify with `publicKey` (raw 32 bytes, compiled into the app).
	public static func verify(file: URL, info: UpdateInfo, publicKey: Data) throws {
		guard let key = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKey) else { throw Failure.badKey }
		let digest = try sha256(of: file)
		guard digest.map({ String(format: "%02x", $0) }).joined() == info.sha256.lowercased() else { throw Failure.digestMismatch }
		guard let signature = Data(base64Encoded: info.signature), key.isValidSignature(signature, for: digest) else {
			throw Failure.badSignature
		}
	}
}
