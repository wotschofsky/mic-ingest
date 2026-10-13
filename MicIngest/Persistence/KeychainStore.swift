import Foundation
import Security

enum KeychainError: LocalizedError {
    case unexpectedStatus(OSStatus)

    var errorDescription: String? {
        switch self {
        case .unexpectedStatus(let status):
            // The status code only; never the secret.
            "Keychain error (\(status)): \(SecCopyErrorMessageString(status, nil) as String? ?? "unknown")"
        }
    }
}

/// API credentials live here and nowhere else (not UserDefaults, not files, not logs).
/// Uses the classic login keychain: the data-protection keychain would need a provisioning profile.
/// Items are tied to the signing identity, so a build signed differently (Apple Development vs
/// Developer ID) asks once for access, or the keys have to be entered again.
struct KeychainStore {
    enum Account: String, CaseIterable {
        case assemblyAI = "assemblyai-api-key"
        case groq = "groq-api-key"
    }

    var service = AppConfig.keychainService

    private func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    /// Stores or replaces the secret. An empty value deletes the item.
    func set(_ secret: String, for account: String) throws {
        let trimmed = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return try delete(account) }
        let data = Data(trimmed.utf8)
        let status = SecItemUpdate(query(account) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var attributes = query(account)
            attributes[kSecValueData as String] = data
            attributes[kSecAttrLabel as String] = "\(AppConfig.appName) – \(account)"
            let added = SecItemAdd(attributes as CFDictionary, nil)
            guard added == errSecSuccess else { throw KeychainError.unexpectedStatus(added) }
        } else if status != errSecSuccess {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    /// Returns nil when no credential is stored.
    func get(_ account: String) throws -> String? {
        var query = query(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw KeychainError.unexpectedStatus(status) }
        return String(data: data, encoding: .utf8)
    }

    func delete(_ account: String) throws {
        let status = SecItemDelete(query(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError.unexpectedStatus(status) }
    }

    func set(_ secret: String, for account: Account) throws { try set(secret, for: account.rawValue) }
    func get(_ account: Account) -> String? { (try? get(account.rawValue)) ?? nil }
    func delete(_ account: Account) throws { try delete(account.rawValue) }
}
