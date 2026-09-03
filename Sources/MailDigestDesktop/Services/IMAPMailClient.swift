import Foundation
import Network

enum IMAPError: LocalizedError {
    case missingConfiguration
    case missingPassword
    case connectionFailed(String)
    case authenticationFailed
    case commandFailed(String)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .missingConfiguration:
            L10n.text("IMAP 配置不完整。", "The IMAP configuration is incomplete.")
        case .missingPassword:
            L10n.text("没有找到这个邮箱的应用专用密码。", "No app password was found for this mailbox.")
        case .connectionFailed(let detail):
            L10n.text("无法连接 IMAP 服务器：\(detail)", "Could not connect to the IMAP server: \(detail)")
        case .authenticationFailed:
            L10n.text("IMAP 登录失败，请检查邮箱地址和应用专用密码。", "IMAP sign-in failed. Check the address and app password.")
        case .commandFailed(let detail):
            L10n.text("IMAP 服务器拒绝了请求：\(detail)", "The IMAP server rejected the request: \(detail)")
        case .invalidResponse:
            L10n.text("IMAP 服务器返回了无法识别的数据。", "The IMAP server returned an unrecognized response.")
        }
    }
}

enum IMAPPreset {
    static func configuration(for emailAddress: String) -> IMAPConfiguration {
        let email = emailAddress.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let domain = email.split(separator: "@").last.map(String.init) ?? ""
        let host: String
        switch domain {
        case "icloud.com", "me.com", "mac.com": host = "imap.mail.me.com"
        case "yahoo.com", "yahoo.com.cn": host = "imap.mail.yahoo.com"
        case "qq.com": host = "imap.qq.com"
        case "163.com": host = "imap.163.com"
        case "126.com": host = "imap.126.com"
        case "yeah.net": host = "imap.yeah.net"
        default: host = domain.isEmpty ? "" : "imap.\(domain)"
        }
        return IMAPConfiguration(
            emailAddress: email,
            host: host,
            port: 993,
            username: email,
            useTLS: true
        )
    }
}

struct IMAPMailClient: Sendable {
    private let keychain: KeychainStore

    init(keychain: KeychainStore = .shared) {
        self.keychain = keychain
    }

    func test(configuration: IMAPConfiguration, password: String) async throws {
        let session = try await IMAPSession.connect(configuration: configuration)
        defer { session.cancel() }
        try await session.login(username: configuration.username, password: password)
        try await session.examineInbox()
        try? await session.logout()
    }

    func fetchNewMessages(for account: MailAccount, since: Date) async throws -> [MailMessage] {
        guard let configuration = account.imapConfiguration else {
            throw IMAPError.missingConfiguration
        }
        guard let password = try keychain.get(
            account: SecretKey.imapPasswordAccount(for: account.id)
        ), !password.isEmpty else {
            throw IMAPError.missingPassword
        }

        let session = try await IMAPSession.connect(configuration: configuration)
        defer { session.cancel() }
        try await session.login(username: configuration.username, password: password)
        try await session.examineInbox()
        let uids = try await session.search(since: since)
        var messages: [MailMessage] = []
        for uid in uids.suffix(250) {
            guard let raw = try await session.fetch(uid: uid),
                  let parsed = RawEmailParser.parse(raw),
                  parsed.receivedAt > since
            else { continue }
            messages.append(MailMessage(
                id: parsed.messageID.isEmpty ? "imap-\(uid)" : parsed.messageID,
                threadID: parsed.messageID.isEmpty ? "imap-\(uid)" : parsed.messageID,
                accountID: account.id,
                subject: parsed.subject,
                sender: parsed.sender,
                receivedAt: parsed.receivedAt,
                bodyText: parsed.body,
                originalURL: nil,
                attachments: [],
                headers: parsed.headers
            ))
        }
        try? await session.logout()
        return messages
    }
}

private final class IMAPSession: @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "MailDigest.IMAP")
    private var buffered = Data()
    private var nextTagNumber = 1

    private init(connection: NWConnection) {
        self.connection = connection
    }

    static func connect(configuration: IMAPConfiguration) async throws -> IMAPSession {
        guard !configuration.host.isEmpty,
              configuration.useTLS,
              let port = NWEndpoint.Port(rawValue: UInt16(configuration.port))
        else { throw IMAPError.missingConfiguration }

        let parameters = configuration.useTLS ? NWParameters(tls: .init()) : NWParameters.tcp
        let session = IMAPSession(connection: NWConnection(
            host: NWEndpoint.Host(configuration.host),
            port: port,
            using: parameters
        ))
        try await session.start()
        let greeting = try await session.readUntilLine()
        guard greeting.uppercased().contains("OK") else {
            throw IMAPError.connectionFailed(greeting)
        }
        return session
    }

    func cancel() {
        connection.cancel()
    }

    func login(username: String, password: String) async throws {
        let response = try await command("LOGIN \(quote(username)) \(quote(password))")
        guard response.uppercased().contains(" OK") else {
            throw IMAPError.authenticationFailed
        }
    }

    func examineInbox() async throws {
        _ = try await command("EXAMINE INBOX")
    }

    func search(since: Date) async throws -> [Int] {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "dd-MMM-yyyy"
        let response = try await command("UID SEARCH SINCE \(formatter.string(from: since))")
        guard let line = response.components(separatedBy: "\r\n").first(where: {
            $0.uppercased().hasPrefix("* SEARCH")
        }) else { return [] }
        return line.split(separator: " ").dropFirst(2).compactMap { Int($0) }
    }

    func fetch(uid: Int) async throws -> Data? {
        let response = try await commandData("UID FETCH \(uid) (BODY.PEEK[])")
        guard let marker = literalMarker(in: response) else { return nil }
        let start = marker.range.upperBound
        guard response.distance(from: start, to: response.endIndex) >= marker.length else {
            throw IMAPError.invalidResponse
        }
        return response.subdata(in: start ..< response.index(start, offsetBy: marker.length))
    }

    func logout() async throws {
        _ = try await command("LOGOUT")
    }

    private func start() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    self.connection.stateUpdateHandler = nil
                    continuation.resume()
                case .failed(let error), .waiting(let error):
                    self.connection.stateUpdateHandler = nil
                    continuation.resume(throwing: IMAPError.connectionFailed(error.localizedDescription))
                case .cancelled:
                    self.connection.stateUpdateHandler = nil
                    continuation.resume(throwing: IMAPError.connectionFailed("cancelled"))
                default:
                    break
                }
            }
            connection.start(queue: queue)
        }
    }

    private func command(_ value: String) async throws -> String {
        let data = try await commandData(value)
        return String(decoding: data, as: UTF8.self)
    }

    private func commandData(_ value: String) async throws -> Data {
        let tag = String(format: "A%04d", nextTagNumber)
        nextTagNumber += 1
        try await send(Data("\(tag) \(value)\r\n".utf8))
        let response = try await readUntilTagged(tag)
        let text = String(decoding: response, as: UTF8.self)
        guard text.range(of: "\r\n\(tag) OK", options: [.caseInsensitive]) != nil
                || text.hasPrefix("\(tag) OK")
        else {
            throw IMAPError.commandFailed(text.components(separatedBy: "\r\n").suffix(2).joined(separator: " "))
        }
        return response
    }

    private func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: IMAPError.connectionFailed(error.localizedDescription))
                } else {
                    continuation.resume()
                }
            })
        }
    }

    private func readUntilLine() async throws -> String {
        while true {
            if let range = buffered.range(of: Data("\r\n".utf8)) {
                let line = buffered.subdata(in: buffered.startIndex ..< range.lowerBound)
                buffered.removeSubrange(buffered.startIndex ..< range.upperBound)
                return String(decoding: line, as: UTF8.self)
            }
            buffered.append(try await receive())
        }
    }

    private func readUntilTagged(_ tag: String) async throws -> Data {
        let success = Data("\r\n\(tag) OK".utf8)
        let failure = Data("\r\n\(tag) NO".utf8)
        let bad = Data("\r\n\(tag) BAD".utf8)
        while true {
            if let completion = [success, failure, bad].compactMap({ marker -> Range<Data.Index>? in
                guard let markerRange = buffered.range(of: marker),
                      let lineEnd = buffered[markerRange.lowerBound...].range(of: Data("\r\n".utf8))
                else { return nil }
                return buffered.startIndex ..< lineEnd.upperBound
            }).min(by: { $0.upperBound < $1.upperBound }) {
                let result = buffered.subdata(in: completion)
                buffered.removeSubrange(completion)
                return result
            }
            buffered.append(try await receive())
        }
    }

    private func receive() async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) {
                data, _, isComplete, error in
                if let error {
                    continuation.resume(throwing: IMAPError.connectionFailed(error.localizedDescription))
                } else if let data, !data.isEmpty {
                    continuation.resume(returning: data)
                } else if isComplete {
                    continuation.resume(throwing: IMAPError.connectionFailed("connection closed"))
                } else {
                    continuation.resume(throwing: IMAPError.invalidResponse)
                }
            }
        }
    }

    private func quote(_ value: String) -> String {
        "\"\(value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\""
    }

    private func literalMarker(in data: Data) -> (range: Range<Data.Index>, length: Int)? {
        let text = String(decoding: data, as: UTF8.self)
        guard let regex = try? NSRegularExpression(pattern: #"\{(\d+)\}\r\n"#),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let lengthRange = Range(match.range(at: 1), in: text),
              let length = Int(text[lengthRange]),
              let markerRange = Range(match.range(at: 0), in: text)
        else { return nil }
        let lower = text[..<markerRange.lowerBound].utf8.count
        let upper = text[..<markerRange.upperBound].utf8.count
        return (data.index(data.startIndex, offsetBy: lower) ..< data.index(data.startIndex, offsetBy: upper), length)
    }
}

struct ParsedRawEmail {
    var messageID: String
    var subject: String
    var sender: String
    var receivedAt: Date
    var body: String
    var headers: [String: String]
}

enum RawEmailParser {
    static func parse(_ data: Data) -> ParsedRawEmail? {
        let source = String(decoding: data, as: UTF8.self)
        let separator = source.range(of: "\r\n\r\n") ?? source.range(of: "\n\n")
        guard let separator else { return nil }
        let headerText = String(source[..<separator.lowerBound])
        let bodyText = String(source[separator.upperBound...])
        let headers = parseHeaders(headerText)
        let subject = decodeHeader(headers["subject"] ?? L10n.text("（无主题）", "(No subject)"))
        let sender = decodeHeader(headers["from"] ?? L10n.text("未知发件人", "Unknown sender"))
        let messageID = headers["message-id"]?.trimmingCharacters(in: CharacterSet(charactersIn: "<> ")) ?? ""
        let date = parseDate(headers["date"]) ?? .now
        let body = preferredBody(headers: headers, body: bodyText)
        return ParsedRawEmail(
            messageID: messageID,
            subject: subject,
            sender: sender,
            receivedAt: date,
            body: EmailContentCleaner.clean(body),
            headers: headers
        )
    }

    private static func parseHeaders(_ value: String) -> [String: String] {
        let unfolded = value.replacingOccurrences(of: "\r\n\t", with: " ")
            .replacingOccurrences(of: "\r\n ", with: " ")
            .replacingOccurrences(of: "\n\t", with: " ")
            .replacingOccurrences(of: "\n ", with: " ")
        var result: [String: String] = [:]
        for line in unfolded.components(separatedBy: .newlines) {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].lowercased()
            let content = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if result[key] == nil { result[key] = content }
        }
        return result
    }

    private static func preferredBody(headers: [String: String], body: String) -> String {
        let contentType = headers["content-type"]?.lowercased() ?? "text/plain"
        if contentType.contains("multipart/"),
           let boundary = parameter(named: "boundary", in: headers["content-type"] ?? "") {
            let parts = body.components(separatedBy: "--\(boundary)")
            var htmlFallback: String?
            for part in parts {
                guard let separator = part.range(of: "\r\n\r\n") ?? part.range(of: "\n\n") else { continue }
                let partHeaders = parseHeaders(String(part[..<separator.lowerBound]))
                let partBody = String(part[separator.upperBound...])
                let type = partHeaders["content-type"]?.lowercased() ?? ""
                guard type.hasPrefix("text/") else { continue }
                let decoded = decodeBody(partBody, encoding: partHeaders["content-transfer-encoding"])
                if type.hasPrefix("text/plain") { return decoded }
                if type.hasPrefix("text/html") { htmlFallback = stripHTML(decoded) }
            }
            return htmlFallback ?? ""
        }
        let decoded = decodeBody(body, encoding: headers["content-transfer-encoding"])
        return contentType.contains("text/html") ? stripHTML(decoded) : decoded
    }

    private static func parameter(named name: String, in value: String) -> String? {
        let pattern = "(?i)\\b\(NSRegularExpression.escapedPattern(for: name))\\s*=\\s*(?:\"([^\"]+)\"|([^;\\s]+))"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value))
        else { return nil }
        for index in 1...2 where match.range(at: index).location != NSNotFound {
            if let range = Range(match.range(at: index), in: value) { return String(value[range]) }
        }
        return nil
    }

    private static func decodeBody(_ value: String, encoding: String?) -> String {
        switch encoding?.lowercased() {
        case "base64":
            let compact = value.filter { !$0.isWhitespace }
            return Data(base64Encoded: compact).map { String(decoding: $0, as: UTF8.self) } ?? value
        case "quoted-printable":
            return decodeQuotedPrintable(value)
        default:
            return value
        }
    }

    private static func decodeHeader(_ value: String) -> String {
        let pattern = #"=\?[^?]+\?([bBqQ])\?([^?]+)\?="#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return value }
        var output = value
        for match in regex.matches(in: value, range: NSRange(value.startIndex..., in: value)).reversed() {
            guard let full = Range(match.range(at: 0), in: value),
                  let kind = Range(match.range(at: 1), in: value),
                  let payload = Range(match.range(at: 2), in: value)
            else { continue }
            let encoded = String(value[payload])
            let decoded: String
            if value[kind].lowercased() == "b" {
                decoded = Data(base64Encoded: encoded).map { String(decoding: $0, as: UTF8.self) } ?? encoded
            } else {
                decoded = decodeQuotedPrintable(encoded.replacingOccurrences(of: "_", with: " "))
            }
            output.replaceSubrange(full, with: decoded)
        }
        return output
    }

    private static func decodeQuotedPrintable(_ value: String) -> String {
        let input = Array(value.replacingOccurrences(of: "=\r\n", with: "").utf8)
        var output = Data()
        var index = 0
        while index < input.count {
            if input[index] == 61, index + 2 < input.count,
               let high = hex(input[index + 1]), let low = hex(input[index + 2]) {
                output.append(high * 16 + low)
                index += 3
            } else {
                output.append(input[index])
                index += 1
            }
        }
        return String(decoding: output, as: UTF8.self)
    }

    private static func hex(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 48...57: byte - 48
        case 65...70: byte - 55
        case 97...102: byte - 87
        default: nil
        }
    }

    private static func stripHTML(_ value: String) -> String {
        value.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func parseDate(_ value: String?) -> Date? {
        guard let value else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        for format in ["EEE, d MMM yyyy HH:mm:ss Z", "EEE, dd MMM yyyy HH:mm:ss Z", "d MMM yyyy HH:mm:ss Z"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: value) { return date }
        }
        return nil
    }
}
