import Foundation

enum OpenAIServiceError: LocalizedError {
    case missingAPIKey
    case invalidResponse
    case requestFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            L10n.text("尚未在设置中保存 OpenAI API 密钥。", "No OpenAI API key is saved in Settings.")
        case .invalidResponse:
            L10n.text("OpenAI 返回了无法识别的摘要结果。", "OpenAI returned an unrecognized digest result.")
        case .requestFailed(let message): message
        }
    }
}

struct OpenAIEmailSummarizer: EmailSummarizing {
    let model: String
    let language: AppLanguage
    private let session: URLSession
    private let keychain: KeychainStore
    private static let requestGate = OpenAIRequestGate(minimumInterval: 1.25)
    private static let maximumAttempts = 4

    init(
        model: String,
        language: AppLanguage = L10n.language,
        session: URLSession = .shared,
        keychain: KeychainStore = .shared
    ) {
        self.model = model
        self.language = language
        self.session = session
        self.keychain = keychain
    }

    func summarize(message: MailMessage, attachmentText: String) async throws -> [SummarizedAction] {
        guard let apiKey = try keychain.get(.openAI), !apiKey.isEmpty else {
            throw OpenAIServiceError.missingAPIKey
        }

        let endpoint = URL(string: "https://api.openai.com/v1/responses")!
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 60

        let sourceText = composeSourceText(message: message, attachmentText: attachmentText)
        let body: [String: Any] = [
            "model": model,
            "store": false,
            "safety_identifier": Self.safetyIdentifier,
            "reasoning": ["effort": "low"],
            "instructions": Self.instructions(language: language),
            "input": sourceText,
            "max_output_tokens": 4_000,
            "text": [
                "verbosity": "low",
                "format": [
                    "type": "json_schema",
                    "name": "email_digest_actions",
                    "strict": true,
                    "schema": Self.outputSchema
                ]
            ]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        var attempt = 0
        var responseData: Data?
        while attempt < Self.maximumAttempts {
            attempt += 1
            await Self.requestGate.waitForTurn()

            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw OpenAIServiceError.invalidResponse
            }

            if (200..<300).contains(httpResponse.statusCode) {
                responseData = data
                break
            }

            let details = Self.serverErrorDetails(from: data)
            let isTemporaryRateLimit = httpResponse.statusCode == 429
                && details.code != "insufficient_quota"
                && details.type != "insufficient_quota"

            if isTemporaryRateLimit, attempt < Self.maximumAttempts {
                let delay = Self.retryDelay(
                    retryAfter: httpResponse.value(forHTTPHeaderField: "Retry-After"),
                    attempt: attempt
                )
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                continue
            }

            let serverMessage = Self.serverErrorMessage(from: data)
            throw OpenAIServiceError.requestFailed(
                serverMessage ?? L10n.text(
                    "OpenAI 请求失败（\(httpResponse.statusCode)）。",
                    "The OpenAI request failed (\(httpResponse.statusCode))."
                )
            )
        }

        guard let data = responseData else {
            throw OpenAIServiceError.requestFailed(L10n.text(
                "OpenAI 仍在限流。程序已经自动重试，请稍后再试。",
                "OpenAI is still rate limiting requests. The app retried automatically; try again later."
            ))
        }

        let outputText = try OpenAIResponseParser.outputText(from: data)
        guard let jsonData = OpenAIResponseParser.jsonData(from: outputText) else {
            throw OpenAIServiceError.invalidResponse
        }

        let decoded: ActionEnvelope
        do {
            decoded = try JSONDecoder().decode(ActionEnvelope.self, from: jsonData)
        } catch {
            throw OpenAIServiceError.requestFailed(
                L10n.text(
                    "OpenAI 摘要字段格式不兼容（\(OpenAIResponseParser.safeDecodingDescription(error))）。",
                    "The OpenAI digest fields were incompatible (\(OpenAIResponseParser.safeDecodingDescription(error)))."
                )
            )
        }
        return decoded.actions.map { action in
            SummarizedAction(
                actionKey: action.actionKey,
                summary: action.summary,
                deadline: action.deadline.flatMap(Self.parseDate),
                deadlineEnd: action.endTime.flatMap(Self.parseDate),
                deadlineHasTime: action.deadlineHasTime ?? false,
                priority: DigestPriority(rawValue: action.priority) ?? .normal,
                mailType: MailType(rawValue: decoded.emailType) ?? .other
            )
        }
    }

    private func composeSourceText(message: MailMessage, attachmentText: String) -> String {
        let maximumCharacters = 36_000
        let combined = """
        邮件标题：\(message.subject)
        发件人：\(message.sender)
        接收时间：\(message.receivedAt.formatted(date: .long, time: .shortened))
        当前时间：\(Date.now.formatted(date: .long, time: .complete))
        本机时区：\(TimeZone.current.identifier)

        邮件正文：
        \(message.bodyText)

        附件提取文字：
        \(attachmentText.isEmpty ? "（无）" : attachmentText)
        """
        return String(combined.prefix(maximumCharacters))
    }

    private static func instructions(language: AppLanguage) -> String {
        let outputLanguage = language == .english ? "English" : "简体中文"
        return """
        你负责把一封邮件整理为简洁的桌面摘要，所有 summary 必须使用\(outputLanguage)。普通通知也必须生成摘要；若邮件包含多个彼此独立、可以分别完成的行动项，则拆成多条。每条只写一句自然、明确的话，不要添加邮件中没有的事实。action_key 使用简短稳定的英文短语。deadline 必须是含时区的 ISO 8601 时间；没有明确日期时为 null。deadline_has_time 仅在邮件明确给出具体时间时为 true；如果只有日期，则为 false，并用该日期本机时区中午12:00作为 deadline 的占位时间。若邮件明确给出一项日程的开始和结束时间，deadline 填开始时间，end_time 填结束时间；没有明确结束时间时 end_time 为 null。根据截止日期、发件人和紧急措辞给出 urgent、important 或 normal。email_type 必须对整封邮件只选择一个最主要的类型：action_required、school、finance、shopping、travel、newsletter、promotion、spam_low_priority 或 other。promotion 只用于以促销、折扣、优惠券、新品或购买号召为主要目的的营销广告。订单确认、付款收据、账单、物流、账户安全、学校通知和需要用户操作的邮件不得标为 promotion；纯信息型订阅通讯优先标为 newsletter。
        """
    }

    private static let outputSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "email_type": [
                "type": "string",
                "enum": [
                    "action_required", "school", "finance", "shopping",
                    "travel", "newsletter", "promotion", "spam_low_priority", "other"
                ]
            ],
            "actions": [
                "type": "array",
                "minItems": 1,
                "items": [
                    "type": "object",
                    "properties": [
                        "action_key": ["type": "string"],
                        "summary": ["type": "string"],
                        "deadline": ["type": ["string", "null"]],
                        "end_time": ["type": ["string", "null"]],
                        "deadline_has_time": ["type": "boolean"],
                        "priority": ["type": "string", "enum": ["urgent", "important", "normal"]]
                    ],
                    "required": ["action_key", "summary", "deadline", "end_time", "deadline_has_time", "priority"],
                    "additionalProperties": false
                ]
            ]
        ],
        "required": ["email_type", "actions"],
        "additionalProperties": false
    ]

    private static var safetyIdentifier: String {
        let defaults = UserDefaults.standard
        let key = "openai.safety-identifier"
        if let existing = defaults.string(forKey: key) { return existing }
        let value = "mail-digest-\(UUID().uuidString.lowercased())"
        defaults.set(value, forKey: key)
        return value
    }

    private static func parseDate(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }

    static func serverErrorMessage(from data: Data) -> String? {
        let details = serverErrorDetails(from: data)
        switch details.code ?? details.type {
        case "insufficient_quota":
            return L10n.text(
                "OpenAI API 没有可用额度。请在 OpenAI Platform 添加付款方式或充值后重试。",
                "The OpenAI API has no available credits. Add a payment method or credits in OpenAI Platform, then retry."
            )
        case "invalid_api_key":
            return L10n.text(
                "OpenAI API 密钥无效。请在设置中保存一个有效的新密钥。",
                "The OpenAI API key is invalid. Save a valid new key in Settings."
            )
        case "rate_limit_exceeded":
            return L10n.text(
                "OpenAI 仍在限流。程序已经自动重试，请稍后再试。",
                "OpenAI is still rate limiting requests. The app retried automatically; try again later."
            )
        case "model_not_found":
            return L10n.text(
                "当前 OpenAI 账号无法使用所选摘要模型，请在设置中选择其他模型。",
                "The selected digest model is unavailable to this OpenAI account. Choose another model in Settings."
            )
        default:
            return details.message
        }
    }

    static func retryDelay(
        retryAfter: String?,
        attempt: Int,
        jitter: Double = .random(in: 0.15...0.65)
    ) -> TimeInterval {
        if let retryAfter,
           let seconds = TimeInterval(retryAfter.trimmingCharacters(in: .whitespacesAndNewlines)),
           seconds >= 0 {
            return min(seconds + jitter, 60)
        }

        let exponential = pow(2, Double(max(attempt - 1, 0)))
        return min(exponential + jitter, 30)
    }

    private static func serverErrorDetails(from data: Data) -> ServerErrorDetails {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = object["error"] as? [String: Any]
        else { return ServerErrorDetails(code: nil, type: nil, message: nil) }

        return ServerErrorDetails(
            code: error["code"] as? String,
            type: error["type"] as? String,
            message: error["message"] as? String
        )
    }
}

private actor OpenAIRequestGate {
    private let minimumInterval: TimeInterval
    private var nextRequestAt = Date.distantPast

    init(minimumInterval: TimeInterval) {
        self.minimumInterval = minimumInterval
    }

    func waitForTurn() async {
        let now = Date()
        let scheduledAt = max(now, nextRequestAt)
        nextRequestAt = scheduledAt.addingTimeInterval(minimumInterval)
        let delay = scheduledAt.timeIntervalSince(now)
        if delay > 0 {
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
    }
}

private struct ServerErrorDetails {
    let code: String?
    let type: String?
    let message: String?
}

struct OpenAIResponseParser {
    static func outputText(from data: Data) throws -> String {
        let envelope: ResponseEnvelope
        do {
            envelope = try JSONDecoder().decode(ResponseEnvelope.self, from: data)
        } catch {
            throw OpenAIServiceError.invalidResponse
        }

        if envelope.status == "incomplete" {
            let reason = envelope.incompleteDetails?.reason
                ?? L10n.text("输出未完成", "output incomplete")
            throw OpenAIServiceError.requestFailed(L10n.text(
                "OpenAI 摘要输出不完整（\(reason)），请重试。",
                "The OpenAI digest output was incomplete (\(reason)). Try again."
            ))
        }

        if let topLevel = envelope.outputText?.trimmingCharacters(in: .whitespacesAndNewlines),
           !topLevel.isEmpty {
            return topLevel
        }

        if let nested = envelope.output
            .flatMap({ $0.content ?? [] })
            .first(where: { $0.type == "output_text" && $0.text?.isEmpty == false })?
            .text {
            return nested
        }

        if let refusal = envelope.output
            .flatMap({ $0.content ?? [] })
            .first(where: { $0.type == "refusal" })?
            .refusal,
           !refusal.isEmpty {
            throw OpenAIServiceError.requestFailed(L10n.text(
                "OpenAI 未能整理这封邮件：\(refusal)",
                "OpenAI could not organize this email: \(refusal)"
            ))
        }

        throw OpenAIServiceError.invalidResponse
    }

    static func jsonData(from outputText: String) -> Data? {
        var value = outputText.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("```") {
            let lines = value.split(separator: "\n", omittingEmptySubsequences: false)
            if lines.count >= 3 {
                value = lines.dropFirst().dropLast().joined(separator: "\n")
            }
        }
        if let first = value.firstIndex(of: "{"),
           let last = value.lastIndex(of: "}"),
           first <= last {
            value = String(value[first...last])
        }
        return value.data(using: .utf8)
    }

    static func safeDecodingDescription(_ error: Error) -> String {
        func path(_ context: DecodingError.Context) -> String {
            let value = context.codingPath.map(\.stringValue).joined(separator: ".")
            return value.isEmpty ? L10n.text("根对象", "root object") : value
        }
        switch error {
        case DecodingError.keyNotFound(let key, let context):
            return L10n.text(
                "缺少字段 \(key.stringValue)，位置 \(path(context))",
                "missing field \(key.stringValue) at \(path(context))"
            )
        case DecodingError.typeMismatch(let type, let context):
            return L10n.text(
                "字段类型不是 \(type)，位置 \(path(context))",
                "field is not \(type) at \(path(context))"
            )
        case DecodingError.valueNotFound(let type, let context):
            return L10n.text(
                "缺少 \(type) 值，位置 \(path(context))",
                "missing \(type) value at \(path(context))"
            )
        case DecodingError.dataCorrupted(let context):
            return L10n.text(
                "JSON 数据损坏，位置 \(path(context))",
                "corrupt JSON at \(path(context))"
            )
        default:
            return L10n.text("未知解码错误", "unknown decoding error")
        }
    }
}

private struct ResponseEnvelope: Decodable {
    struct Output: Decodable {
        struct Content: Decodable {
            let type: String?
            let text: String?
            let refusal: String?
        }

        let content: [Content]?
    }

    struct IncompleteDetails: Decodable {
        let reason: String?
    }

    let outputText: String?
    let output: [Output]
    let status: String?
    let incompleteDetails: IncompleteDetails?

    enum CodingKeys: String, CodingKey {
        case outputText = "output_text"
        case output
        case status
        case incompleteDetails = "incomplete_details"
    }
}

private struct ActionEnvelope: Decodable {
    struct Action: Decodable {
        let actionKey: String
        let summary: String
        let deadline: String?
        let endTime: String?
        let deadlineHasTime: Bool?
        let priority: String

        enum CodingKeys: String, CodingKey {
            case actionKey = "action_key"
            case summary
            case deadline
            case endTime = "end_time"
            case deadlineHasTime = "deadline_has_time"
            case priority
        }
    }

    let emailType: String
    let actions: [Action]

    enum CodingKeys: String, CodingKey {
        case emailType = "email_type"
        case actions
    }
}
