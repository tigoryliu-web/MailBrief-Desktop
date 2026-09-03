import AppKit
import Foundation

actor OAuthCoordinator {
    private let keychain: KeychainStore
    private let session: URLSession

    init(keychain: KeychainStore = .shared, session: URLSession = .shared) {
        self.keychain = keychain
        self.session = session
    }

    func authorize(_ account: MailAccount) async throws -> OAuthTokenSet {
        switch account.provider {
        case .gmail:
            return try await authorizeGoogle(accountID: account.id)
        case .outlook:
            return try await authorizeMicrosoft(accountID: account.id)
        case .imap:
            throw OAuthSetupError.invalidAccount
        }
    }

    private func authorizeGoogle(accountID: String) async throws -> OAuthTokenSet {
        guard let client = try keychain.getCodable(GoogleOAuthClient.self, for: .googleOAuthClient) else {
            throw OAuthSetupError.missingGoogleClient
        }
        let tokenKey = SecretKey.tokenAccount(for: accountID)

        let state = UUID().uuidString
        let pkce = try PKCEPair.generate()
        let server = try LoopbackOAuthServer(expectedState: state)
        let port = try await server.start()
        let redirectURI = "http://127.0.0.1:\(port)"

        var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: client.clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: "https://www.googleapis.com/auth/gmail.readonly"),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent select_account"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256")
        ]
        guard let authorizationURL = components.url else {
            server.cancel()
            throw OAuthSetupError.invalidCallback
        }
        guard await MainActor.run(body: { NSWorkspace.shared.open(authorizationURL) }) else {
            server.cancel()
            throw OAuthSetupError.browserCouldNotOpen
        }

        let callbackURL = try await server.waitForCallback()
        let code = try parseAuthorizationCode(callbackURL)
        let response: TokenResponse = try await exchangeToken(
            url: URL(string: "https://oauth2.googleapis.com/token")!,
            parameters: [
                "client_id": client.clientID,
                "client_secret": client.clientSecret,
                "code": code,
                "code_verifier": pkce.verifier,
                "redirect_uri": redirectURI,
                "grant_type": "authorization_code"
            ]
        )
        guard let refreshToken = response.refreshToken else {
            throw OAuthSetupError.missingRefreshToken
        }

        let email = try? await googleEmailAddress(accessToken: response.accessToken)
        let tokens = OAuthTokenSet(
            accessToken: response.accessToken,
            refreshToken: refreshToken,
            expiresAt: .now.addingTimeInterval(response.expiresIn),
            accountEmail: email,
            grantedScope: response.scope
        )
        try keychain.setCodable(tokens, account: tokenKey)
        return tokens
    }

    private func authorizeMicrosoft(accountID: String) async throws -> OAuthTokenSet {
        guard let clientID = try keychain.get(.microsoftClientID), !clientID.isEmpty else {
            throw OAuthSetupError.missingMicrosoftClient
        }
        let tokenKey = SecretKey.tokenAccount(for: accountID)

        let state = UUID().uuidString
        let pkce = try PKCEPair.generate()
        let server = try LoopbackOAuthServer(expectedState: state)
        let port = try await server.start()
        let redirectURI = "http://localhost:\(port)"
        let scope = "offline_access Mail.Read"

        var components = URLComponents(
            string: "https://login.microsoftonline.com/consumers/oauth2/v2.0/authorize"
        )!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "response_mode", value: "query"),
            URLQueryItem(name: "scope", value: scope),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256")
        ]
        guard let authorizationURL = components.url else {
            server.cancel()
            throw OAuthSetupError.invalidCallback
        }
        guard await MainActor.run(body: { NSWorkspace.shared.open(authorizationURL) }) else {
            server.cancel()
            throw OAuthSetupError.browserCouldNotOpen
        }

        let callbackURL = try await server.waitForCallback()
        let code = try parseAuthorizationCode(callbackURL)
        let response: TokenResponse = try await exchangeToken(
            url: URL(string: "https://login.microsoftonline.com/consumers/oauth2/v2.0/token")!,
            parameters: [
                "client_id": clientID,
                "scope": scope,
                "code": code,
                "code_verifier": pkce.verifier,
                "redirect_uri": redirectURI,
                "grant_type": "authorization_code"
            ]
        )
        guard let refreshToken = response.refreshToken else {
            throw OAuthSetupError.missingRefreshToken
        }

        let email = try? await microsoftEmailAddress(accessToken: response.accessToken)
        let tokens = OAuthTokenSet(
            accessToken: response.accessToken,
            refreshToken: refreshToken,
            expiresAt: .now.addingTimeInterval(response.expiresIn),
            accountEmail: email,
            grantedScope: response.scope
        )
        try keychain.setCodable(tokens, account: tokenKey)
        return tokens
    }

    private func parseAuthorizationCode(_ url: URL) throws -> String {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        if let error = items.first(where: { $0.name == "error" })?.value {
            let detail = items.first(where: { $0.name == "error_description" })?.value ?? error
            throw OAuthSetupError.authorizationDenied(detail)
        }
        guard let code = items.first(where: { $0.name == "code" })?.value else {
            throw OAuthSetupError.invalidCallback
        }
        return code
    }

    private func exchangeToken<T: Decodable>(
        url: URL,
        parameters: [String: String]
    ) async throws -> T {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = formEncoded(parameters)

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode)
        else {
            throw OAuthSetupError.tokenExchangeFailed(
                Self.errorMessage(data) ?? L10n.text("服务器拒绝了请求。", "The server rejected the request.")
            )
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func googleEmailAddress(accessToken: String) async throws -> String {
        var request = URLRequest(
            url: URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/profile")!
        )
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode)
        else { throw MailServiceError.invalidResponse }
        return try JSONDecoder().decode(GmailProfile.self, from: data).emailAddress
    }

    private func microsoftEmailAddress(accessToken: String) async throws -> String {
        var components = URLComponents(string: "https://graph.microsoft.com/v1.0/me")!
        components.queryItems = [URLQueryItem(name: "$select", value: "mail,userPrincipalName")]
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode)
        else { throw MailServiceError.invalidResponse }
        let profile = try JSONDecoder().decode(MicrosoftProfile.self, from: data)
        guard let email = profile.mail ?? profile.userPrincipalName, !email.isEmpty else {
            throw MailServiceError.invalidResponse
        }
        return email
    }

    private func formEncoded(_ values: [String: String]) -> Data {
        let body = values
            .sorted(by: { $0.key < $1.key })
            .map { "\($0.key.formURLEncoded)=\($0.value.formURLEncoded)" }
            .joined(separator: "&")
        return Data(body.utf8)
    }

    private static func errorMessage(_ data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return object["error_description"] as? String
            ?? (object["error"] as? [String: Any])?["message"] as? String
            ?? object["error"] as? String
    }
}

private struct TokenResponse: Decodable {
    let accessToken: String
    let expiresIn: TimeInterval
    let refreshToken: String?
    let scope: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case expiresIn = "expires_in"
        case refreshToken = "refresh_token"
        case scope
    }
}

private struct GmailProfile: Decodable {
    let emailAddress: String
}

private struct MicrosoftProfile: Decodable {
    let mail: String?
    let userPrincipalName: String?
}

actor OAuthTokenProvider {
    private let keychain: KeychainStore
    private let session: URLSession

    init(keychain: KeychainStore = .shared, session: URLSession = .shared) {
        self.keychain = keychain
        self.session = session
    }

    func accessToken(for account: MailAccount) async throws -> String {
        let tokenKey = SecretKey.tokenAccount(for: account.id)
        guard var tokens = try keychain.getCodable(OAuthTokenSet.self, account: tokenKey)
        else { throw MailServiceError.accountNotConfigured }

        if tokens.expiresAt > Date.now.addingTimeInterval(300) {
            return tokens.accessToken
        }
        guard let refreshToken = tokens.refreshToken else {
            throw OAuthSetupError.missingRefreshToken
        }

        let response: TokenResponse
        switch account.provider {
        case .gmail:
            guard let client = try keychain.getCodable(GoogleOAuthClient.self, for: .googleOAuthClient) else {
                throw OAuthSetupError.missingGoogleClient
            }
            response = try await refresh(
                url: URL(string: "https://oauth2.googleapis.com/token")!,
                values: [
                    "client_id": client.clientID,
                    "client_secret": client.clientSecret,
                    "refresh_token": refreshToken,
                    "grant_type": "refresh_token"
                ]
            )
        case .outlook:
            guard let clientID = try keychain.get(.microsoftClientID) else {
                throw OAuthSetupError.missingMicrosoftClient
            }
            response = try await refresh(
                url: URL(string: "https://login.microsoftonline.com/consumers/oauth2/v2.0/token")!,
                values: [
                    "client_id": clientID,
                    "scope": "offline_access Mail.Read",
                    "refresh_token": refreshToken,
                    "grant_type": "refresh_token"
                ]
            )
        case .imap:
            throw MailServiceError.accountNotConfigured
        }

        tokens.accessToken = response.accessToken
        tokens.refreshToken = response.refreshToken ?? refreshToken
        tokens.expiresAt = .now.addingTimeInterval(response.expiresIn)
        tokens.grantedScope = response.scope ?? tokens.grantedScope
        try keychain.setCodable(tokens, account: tokenKey)
        return tokens.accessToken
    }

    func accountEmail(for accountID: String) throws -> String? {
        let tokenKey = SecretKey.tokenAccount(for: accountID)
        let tokens = try keychain.getCodable(OAuthTokenSet.self, account: tokenKey)
        return tokens?.accountEmail
    }

    private func refresh(url: URL, values: [String: String]) async throws -> TokenResponse {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let body = values
            .sorted(by: { $0.key < $1.key })
            .map { "\($0.key.formURLEncoded)=\($0.value.formURLEncoded)" }
            .joined(separator: "&")
        request.httpBody = Data(body.utf8)

        let (data, urlResponse) = try await session.data(for: request)
        guard let response = urlResponse as? HTTPURLResponse,
              (200..<300).contains(response.statusCode)
        else {
            throw OAuthSetupError.tokenExchangeFailed(L10n.text(
                "无法刷新邮箱授权。",
                "The mailbox authorization could not be refreshed."
            ))
        }
        return try JSONDecoder().decode(TokenResponse.self, from: data)
    }
}
