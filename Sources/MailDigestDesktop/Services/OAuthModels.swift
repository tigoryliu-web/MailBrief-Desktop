import Foundation

struct GoogleOAuthClient: Codable, Sendable {
    var clientID: String
    var clientSecret: String
}

struct OAuthTokenSet: Codable, Sendable {
    var accessToken: String
    var refreshToken: String?
    var expiresAt: Date
    var accountEmail: String?
    var grantedScope: String?
}

enum OAuthSetupError: LocalizedError {
    case missingGoogleClient
    case missingMicrosoftClient
    case invalidAccount
    case invalidCallback
    case stateMismatch
    case authorizationDenied(String)
    case tokenExchangeFailed(String)
    case missingRefreshToken
    case browserCouldNotOpen

    var errorDescription: String? {
        switch self {
        case .missingGoogleClient:
            return L10n.text("请先保存 Google OAuth 桌面客户端信息。", "Save the Google OAuth desktop client first.")
        case .missingMicrosoftClient:
            return L10n.text("请先保存 Microsoft 应用客户端 ID。", "Save the Microsoft application Client ID first.")
        case .invalidAccount:
            return L10n.text("无法识别这个邮箱账号。", "This mailbox account is not recognized.")
        case .invalidCallback:
            return L10n.text("没有收到有效的授权回调。", "No valid authorization callback was received.")
        case .stateMismatch:
            return L10n.text("授权状态校验失败，请重新尝试。", "Authorization state verification failed. Try again.")
        case .authorizationDenied(let message):
            return L10n.text("授权未完成：\(message)", "Authorization was not completed: \(message)")
        case .tokenExchangeFailed(let message):
            return L10n.text("获取邮箱令牌失败：\(message)", "Could not obtain a mailbox token: \(message)")
        case .missingRefreshToken:
            return L10n.text(
                "邮箱没有返回长期刷新令牌，请撤销旧授权后重试。",
                "The provider did not return a long-lived refresh token. Revoke the old authorization and try again."
            )
        case .browserCouldNotOpen:
            return L10n.text("无法打开系统浏览器。", "The system browser could not be opened.")
        }
    }
}

extension KeychainStore {
    func setCodable<T: Encodable>(_ value: T, for key: SecretKey) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(value)
        guard let string = String(data: data, encoding: .utf8) else {
            throw KeychainError.invalidData
        }
        try set(string, for: key)
    }

    func setCodable<T: Encodable>(_ value: T, account: String) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(value)
        guard let string = String(data: data, encoding: .utf8) else {
            throw KeychainError.invalidData
        }
        try set(string, account: account)
    }

    func getCodable<T: Decodable>(_ type: T.Type, for key: SecretKey) throws -> T? {
        guard let value = try get(key), let data = value.data(using: .utf8) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: data)
    }


    func getCodable<T: Decodable>(_ type: T.Type, account: String) throws -> T? {
        guard let value = try get(account: account), let data = value.data(using: .utf8) else {
            return nil
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: data)
    }
}
