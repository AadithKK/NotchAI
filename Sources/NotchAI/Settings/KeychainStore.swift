import Foundation
import Security

/// Minimal Keychain surface used by settings; tests inject an in-memory implementation.
protocol SecureKeyStoring: AnyObject {
    func set(_ value: String?, for key: String) throws
    func value(for key: String) -> String?
    func removeAll() throws
}

enum KeychainError: LocalizedError {
    case unhandledStatus(OSStatus)

    var errorDescription: String? {
        switch self {
        case let .unhandledStatus(status):
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "status \(status)"
            return "Keychain error: \(message)"
        }
    }
}

/// Stores API keys as generic passwords under the NotchAI service name.
final class KeychainStore: SecureKeyStoring {
    static let defaultService = "com.aadithkannoth.NotchAI"
    static let knownAccounts = ["deepseek-api-key", "gemini-api-key"]

    private let service: String

    init(service: String = KeychainStore.defaultService) {
        self.service = service
    }

    func set(_ value: String?, for key: String) throws {
        guard let value else {
            try delete(key)
            return
        }
        let data = Data(value.utf8)
        let query = baseQuery(account: key)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecItemNotFound {
            var add = query
            attributes.forEach { add[$0.key] = $0.value }
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw KeychainError.unhandledStatus(addStatus) }
        } else if updateStatus != errSecSuccess {
            throw KeychainError.unhandledStatus(updateStatus)
        }
    }

    func value(for key: String) -> String? {
        var query = baseQuery(account: key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func removeAll() throws {
        for account in KeychainStore.knownAccounts {
            try delete(account)
        }
    }

    private func delete(_ key: String) throws {
        let status = SecItemDelete(baseQuery(account: key) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unhandledStatus(status)
        }
    }

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
