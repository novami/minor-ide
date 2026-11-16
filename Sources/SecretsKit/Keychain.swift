import Foundation
import Security

/// Passwords in the file-based login keychain (D19): generic password items of service
/// `MinorIDE`, the account is the id the saved settings refer to. Not synchronized to iCloud.
public struct Keychain: Sendable {
	public let service: String

	public init(service: String = "MinorIDE") {
		self.service = service
	}

	public struct Failure: Error, LocalizedError {
		public let status: OSStatus
		public var errorDescription: String? {
			SecCopyErrorMessageString(status, nil) as String? ?? "Keychain error \(status)"
		}
	}

	private func query(_ id: String) -> [String: Any] {
		[kSecClass as String: kSecClassGenericPassword,
		 kSecAttrService as String: service,
		 kSecAttrAccount as String: id]
	}

	public func password(_ id: String) throws -> String? {
		var q = query(id)
		q[kSecReturnData as String] = true
		q[kSecMatchLimit as String] = kSecMatchLimitOne
		var result: AnyObject?
		let status = SecItemCopyMatching(q as CFDictionary, &result)
		if status == errSecItemNotFound { return nil }
		guard status == errSecSuccess, let data = result as? Data else { throw Failure(status: status) }
		return String(decoding: data, as: UTF8.self)
	}

	/// Stores the password; an empty one deletes the item.
	public func setPassword(_ password: String, _ id: String) throws {
		guard !password.isEmpty else { return try delete(id) }
		let data = Data(password.utf8)
		let status = SecItemUpdate(query(id) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
		if status == errSecItemNotFound {
			var q = query(id)
			q[kSecValueData as String] = data
			q[kSecAttrLabel as String] = service
			let added = SecItemAdd(q as CFDictionary, nil)
			guard added == errSecSuccess else { throw Failure(status: added) }
		} else if status != errSecSuccess {
			throw Failure(status: status)
		}
	}

	public func delete(_ id: String) throws {
		let status = SecItemDelete(query(id) as CFDictionary)
		guard status == errSecSuccess || status == errSecItemNotFound else { throw Failure(status: status) }
	}
}
