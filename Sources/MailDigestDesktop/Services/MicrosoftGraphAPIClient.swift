import Foundation

struct MicrosoftGraphAPIClient: Sendable {
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
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]

        var components = URLComponents(
            string: "https://graph.microsoft.com/v1.0/me/mailFolders/inbox/messages"
        )!
        components.queryItems = [
            URLQueryItem(
                name: "$select",
                value: "id,conversationId,subject,from,receivedDateTime,body,webLink,hasAttachments,internetMessageHeaders"
            ),
            URLQueryItem(name: "$filter", value: "receivedDateTime ge \(formatter.string(from: since))"),
            URLQueryItem(name: "$orderby", value: "receivedDateTime asc"),
            URLQueryItem(name: "$top", value: "100")
        ]

        var nextURL: URL? = components.url
        var resources: [GraphMessage] = []
        while let url = nextURL, resources.count < 2_000 {
            let data = try await get(url, accessToken: accessToken, preferTextBody: true)
            let page = try JSONDecoder().decode(GraphMessagePage.self, from: data)
            resources.append(contentsOf: page.value)
            nextURL = page.nextLink.flatMap(URL.init(string:))
        }

        var messages: [MailMessage] = []
        for resource in resources {
            guard let receivedAt = Self.parseDate(resource.receivedDateTime), receivedAt > since else {
                continue
            }
            let attachments = resource.hasAttachments
                ? try await fetchAttachments(messageID: resource.id, accessToken: accessToken)
                : []
            let headers = GmailHeaderParser.values(
                (resource.internetMessageHeaders ?? []).map { ($0.name, $0.value) }
            )
            messages.append(MailMessage(
                id: resource.id,
                threadID: resource.conversationId ?? resource.id,
                accountID: account.id,
                subject: resource.subject?.isEmpty == false
                    ? resource.subject!
                    : L10n.text("（无主题）", "(No subject)"),
                sender: resource.from?.emailAddress.name
                    ?? resource.from?.emailAddress.address
                    ?? L10n.text("未知发件人", "Unknown sender"),
                receivedAt: receivedAt,
                bodyText: resource.body?.content ?? "",
                originalURL: resource.webLink.flatMap(URL.init(string:)),
                attachments: attachments,
                headers: headers
            ))
        }
        return messages
    }

    private func fetchAttachments(messageID: String, accessToken: String) async throws -> [MailAttachment] {
        let id = messageID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? messageID
        let url = URL(string: "https://graph.microsoft.com/v1.0/me/messages/\(id)/attachments")!
        let data = try await get(url, accessToken: accessToken)
        let page = try JSONDecoder().decode(GraphAttachmentPage.self, from: data)
        return page.value.compactMap { attachment in
            guard attachment.odataType?.contains("fileAttachment") == true,
                  attachment.isInline != true,
                  attachment.size <= maximumAttachmentBytes,
                  let encoded = attachment.contentBytes,
                  let data = Data(base64Encoded: encoded)
            else { return nil }
            return MailAttachment(
                filename: attachment.name,
                mimeType: attachment.contentType ?? "application/octet-stream",
                data: data
            )
        }
    }

    private func get(
        _ url: URL,
        accessToken: String,
        preferTextBody: Bool = false
    ) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        if preferTextBody {
            request.setValue("outlook.body-content-type=\"text\"", forHTTPHeaderField: "Prefer")
        }
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw MailServiceError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw MailServiceError.server(L10n.text(
                "Outlook 同步失败（\(httpResponse.statusCode)）。",
                "Outlook sync failed (\(httpResponse.statusCode))."
            ))
        }
        return data
    }

    private static func parseDate(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let value = formatter.date(from: value) { return value }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }
}

private struct GraphMessagePage: Decodable {
    let value: [GraphMessage]
    let nextLink: String?

    enum CodingKeys: String, CodingKey {
        case value
        case nextLink = "@odata.nextLink"
    }
}

private struct GraphMessage: Decodable {
    struct Sender: Decodable {
        struct EmailAddress: Decodable {
            let name: String?
            let address: String?
        }
        let emailAddress: EmailAddress
    }

    struct Body: Decodable {
        let content: String
    }

    struct InternetMessageHeader: Decodable {
        let name: String
        let value: String
    }

    let id: String
    let conversationId: String?
    let subject: String?
    let from: Sender?
    let receivedDateTime: String
    let body: Body?
    let webLink: String?
    let hasAttachments: Bool
    let internetMessageHeaders: [InternetMessageHeader]?
}

private struct GraphAttachmentPage: Decodable {
    let value: [GraphAttachment]
}

private struct GraphAttachment: Decodable {
    let odataType: String?
    let name: String
    let contentType: String?
    let size: Int
    let isInline: Bool?
    let contentBytes: String?

    enum CodingKeys: String, CodingKey {
        case odataType = "@odata.type"
        case name
        case contentType
        case size
        case isInline
        case contentBytes
    }
}
