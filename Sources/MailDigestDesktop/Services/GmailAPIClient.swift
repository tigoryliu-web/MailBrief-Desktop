import Foundation

struct GmailAPIClient: Sendable {
    private let tokens: OAuthTokenProvider
    private let session: URLSession
    private let maximumAttachmentBytes: Int

    init(
        tokens: OAuthTokenProvider,
        session: URLSession = .shared,
        maximumAttachmentBytes: Int = 20 * 1_024 * 1_024
    ) {
        self.tokens = tokens
        self.session = session
        self.maximumAttachmentBytes = maximumAttachmentBytes
    }

    func fetchNewMessages(for account: MailAccount, since: Date) async throws -> [MailMessage] {
        let accessToken = try await tokens.accessToken(for: account)
        var references: [GmailMessageReference] = []
        var pageToken: String?

        repeat {
            var components = URLComponents(
                string: "https://gmail.googleapis.com/gmail/v1/users/me/messages"
            )!
            var queryItems = [
                URLQueryItem(name: "labelIds", value: "INBOX"),
                URLQueryItem(name: "includeSpamTrash", value: "false"),
                URLQueryItem(name: "maxResults", value: "500"),
                URLQueryItem(
                    name: "q",
                    value: Self.searchQuery(since: since)
                )
            ]
            if let pageToken {
                queryItems.append(URLQueryItem(name: "pageToken", value: pageToken))
            }
            components.queryItems = queryItems

            let data = try await get(components.url!, accessToken: accessToken)
            let page = try JSONDecoder().decode(GmailMessageListPage.self, from: data)
            references.append(contentsOf: page.messages ?? [])
            pageToken = page.nextPageToken
        } while pageToken != nil && references.count < 2_000

        var messages: [MailMessage] = []
        for reference in references {
            let message: MailMessage
            do {
                message = try await fetchMessage(
                    reference,
                    account: account,
                    accessToken: accessToken
                )
            } catch is DecodingError {
                let email = try? await tokens.accountEmail(for: account.id)
                let threadID = reference.threadId ?? reference.id
                message = MailMessage(
                    id: reference.id,
                    threadID: threadID,
                    accountID: account.id,
                    subject: L10n.text("需要查看一封格式特殊的邮件", "An email with unusual formatting needs review"),
                    sender: "Gmail",
                    receivedAt: .now,
                    bodyText: L10n.text(
                        "Gmail 返回的邮件格式无法完整读取，请打开原邮件查看。",
                        "Gmail returned an email that could not be fully decoded. Open the original email to review it."
                    ),
                    originalURL: Self.originalURL(threadID: threadID, email: email ?? nil),
                    attachments: []
                )
            }
            if message.receivedAt > since {
                messages.append(message)
            }
        }
        return messages
    }

    private func fetchMessage(
        _ reference: GmailMessageReference,
        account: MailAccount,
        accessToken: String
    ) async throws -> MailMessage {
        let id = reference.id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? reference.id
        var components = URLComponents(
            string: "https://gmail.googleapis.com/gmail/v1/users/me/messages/\(id)"
        )!
        components.queryItems = [URLQueryItem(name: "format", value: "full")]
        let data = try await get(components.url!, accessToken: accessToken)
        let resource = try JSONDecoder().decode(GmailMessageResource.self, from: data)
        let messageID = resource.id ?? reference.id
        let threadID = resource.threadId ?? reference.threadId ?? messageID

        let headers = GmailHeaderParser.values(
            (resource.payload?.headers ?? []).compactMap {
                guard let name = $0.name, let value = $0.value else { return nil }
                return (name, value)
            }
        )
        let bodyText = Self.preferredBodyText(resource.payload) ?? resource.snippet ?? ""
        let attachmentParts = Self.attachmentParts(resource.payload)
        var attachments: [MailAttachment] = []
        for part in attachmentParts where (part.body?.size ?? 0) <= maximumAttachmentBytes {
            let filename = part.filename ?? L10n.text("附件", "Attachment")
            let mimeType = part.mimeType ?? "application/octet-stream"
            if let encoded = part.body?.data, let data = Data(base64URLString: encoded) {
                attachments.append(MailAttachment(
                    filename: filename,
                    mimeType: mimeType,
                    data: data
                ))
            } else if let attachmentID = part.body?.attachmentId {
                if let attachmentData = try? await fetchAttachment(
                    messageID: messageID,
                    attachmentID: attachmentID,
                    accessToken: accessToken
                ) {
                    attachments.append(MailAttachment(
                        filename: filename,
                        mimeType: mimeType,
                        data: attachmentData
                    ))
                }
            }
        }

        let milliseconds = Double(resource.internalDate ?? "") ?? Date.now.timeIntervalSince1970 * 1_000
        let receivedAt = Date(timeIntervalSince1970: milliseconds / 1_000)
        let email = try? await tokens.accountEmail(for: account.id)
        let originalURL = Self.originalURL(threadID: threadID, email: email ?? nil)

        return MailMessage(
            id: messageID,
            threadID: threadID,
            accountID: account.id,
            subject: headers["subject"] ?? L10n.text("（无主题）", "(No subject)"),
            sender: headers["from"] ?? L10n.text("未知发件人", "Unknown sender"),
            receivedAt: receivedAt,
            bodyText: bodyText,
            originalURL: originalURL,
            attachments: attachments,
            headers: headers
        )
    }

    static func searchQuery(since: Date) -> String {
        "after:\(Int(since.timeIntervalSince1970)) -category:promotions"
    }

    private func fetchAttachment(
        messageID: String,
        attachmentID: String,
        accessToken: String
    ) async throws -> Data {
        let message = messageID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? messageID
        let attachment = attachmentID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? attachmentID
        let url = URL(
            string: "https://gmail.googleapis.com/gmail/v1/users/me/messages/\(message)/attachments/\(attachment)"
        )!
        let data = try await get(url, accessToken: accessToken)
        let body = try JSONDecoder().decode(GmailPartBody.self, from: data)
        guard let encoded = body.data, let decoded = Data(base64URLString: encoded) else {
            throw MailServiceError.invalidResponse
        }
        return decoded
    }

    private func get(_ url: URL, accessToken: String) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw MailServiceError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw MailServiceError.server(L10n.text(
                "Gmail 同步失败（\(httpResponse.statusCode)）。",
                "Gmail sync failed (\(httpResponse.statusCode))."
            ))
        }
        return data
    }

    private static func preferredBodyText(_ payload: GmailPart?) -> String? {
        let parts = flattened(payload)
        if let plain = parts.first(where: { $0.mimeType?.lowercased() == "text/plain" }),
           let encoded = plain.body?.data,
           let data = Data(base64URLString: encoded),
           let text = String(data: data, encoding: .utf8) {
            return text
        }
        if let html = parts.first(where: { $0.mimeType?.lowercased() == "text/html" }),
           let encoded = html.body?.data,
           let data = Data(base64URLString: encoded),
           let value = String(data: data, encoding: .utf8) {
            return HTMLText.strip(value)
        }
        return nil
    }

    private static func flattened(_ part: GmailPart?) -> [GmailPart] {
        guard let part else { return [] }
        return [part] + (part.parts ?? []).flatMap { flattened($0) }
    }

    private static func attachmentParts(_ payload: GmailPart?) -> [GmailPart] {
        flattened(payload).filter {
            !($0.filename ?? "").isEmpty
                && (($0.body?.attachmentId != nil) || ($0.body?.data != nil))
        }
    }

    private static func originalURL(threadID: String, email: String?) -> URL? {
        guard var components = URLComponents(string: "https://mail.google.com/mail/u/") else {
            return nil
        }
        if let email {
            components.queryItems = [URLQueryItem(name: "authuser", value: email)]
        }
        components.fragment = "inbox/\(threadID)"
        return components.url
    }
}

enum GmailHeaderParser {
    static func values(_ fields: [(name: String, value: String)]) -> [String: String] {
        Dictionary(
            fields.map { ($0.name.lowercased(), $0.value) },
            uniquingKeysWith: { existing, _ in existing }
        )
    }
}

private struct GmailMessageListPage: Decodable {
    let messages: [GmailMessageReference]?
    let nextPageToken: String?
}

private struct GmailMessageReference: Decodable {
    let id: String
    let threadId: String?
}

private struct GmailMessageResource: Decodable {
    let id: String?
    let threadId: String?
    let internalDate: String?
    let snippet: String?
    let payload: GmailPart?
}

private struct GmailPart: Decodable {
    struct Header: Decodable {
        let name: String?
        let value: String?
    }

    let mimeType: String?
    let filename: String?
    let headers: [Header]?
    let body: GmailPartBody?
    let parts: [GmailPart]?
}

private struct GmailPartBody: Decodable {
    let attachmentId: String?
    let size: Int?
    let data: String?
}

enum HTMLText {
    static func strip(_ html: String) -> String {
        var value = html.replacingOccurrences(
            of: "<(br|BR)\\s*/?>|</(p|div|li|tr)>",
            with: "\n",
            options: .regularExpression
        )
        value = value.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        value = value.replacingOccurrences(of: "&nbsp;", with: " ")
        value = value.replacingOccurrences(of: "&amp;", with: "&")
        value = value.replacingOccurrences(of: "&lt;", with: "<")
        value = value.replacingOccurrences(of: "&gt;", with: ">")
        value = value.replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
        value = value.replacingOccurrences(of: "\\n{3,}", with: "\n\n", options: .regularExpression)
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
