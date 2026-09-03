import Foundation
import Security

enum SecretKey: String, CaseIterable {
    case openAI = "openai.api-key"
    case googleOAuthClient = "google.oauth-client"
    case microsoftClientID = "microsoft.client-id"
    case privateGmailTokens = "gmail.private.tokens"
    case schoolGmailTokens = "gmail.school.tokens"
    case outlookTokens = "outlook.private.tokens"

    static func tokenAccount(for accountID: String) -> String {
        switch accountID {
        case "gmail.private": SecretKey.privateGmailTokens.rawValue
        case "gmail.school": SecretKey.schoolGmailTokens.rawValue
        case "outlook.private": SecretKey.outlookTokens.rawValue
        default: "mail.\(accountID).tokens"
        }
    }

    static func imapPasswordAccount(for accountID: String) -> String {
        "mail.\(accountID).imap-password"
    }
}

enum KeychainError: LocalizedError {
    case unhandledStatus(OSStatus)
    case invalidData

    var errorDescription: String? {
        switch self {
        case .unhandledStatus(let status):
            return SecCopyErrorMessageString(status, nil) as String?
                ?? L10n.text("钥匙串错误：\(status)", "Keychain error: \(status)")
        case .invalidData:
            return L10n.text("钥匙串中的数据格式无效。", "The Keychain data is invalid.")
        }
    }
}

struct KeychainStore {
    static let shared = KeychainStore()
    private let service = "com.mailbrief.desktop"

    func set(_ value: String, for key: SecretKey) throws {
        try set(value, account: key.rawValue)
    }

    func set(_ value: String, account: String) throws {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        SecItemDelete(query as CFDictionary)

        var insert = query
        insert[kSecValueData as String] = data
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(insert as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.unhandledStatus(status)
        }
    }

    func get(_ key: SecretKey) throws -> String? {
        try get(account: key.rawValue)
    }

    func get(account: String) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else {
            throw KeychainError.unhandledStatus(status)
        }
        guard let data = result as? Data,
              let value = String(data: data, encoding: .utf8)
        else {
            throw KeychainError.invalidData
        }
        return value
    }

    func delete(_ key: SecretKey) throws {
        try delete(account: key.rawValue)
    }

    func delete(account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unhandledStatus(status)
        }
    }
}
