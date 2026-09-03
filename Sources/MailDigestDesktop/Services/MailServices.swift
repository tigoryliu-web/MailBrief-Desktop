import Foundation

protocol MailSyncing: Sendable {
    func fetchNewMessages(for account: MailAccount, since: Date) async throws -> [MailMessage]
}

protocol EmailSummarizing: Sendable {
    func summarize(message: MailMessage, attachmentText: String) async throws -> [SummarizedAction]
}

enum MailServiceError: LocalizedError {
    case accountNotConfigured
    case invalidResponse
    case server(String)
    case outlookNotInstalled
    case outlookAutomationDenied
    case outlookAccountMissing

    var errorDescription: String? {
        switch self {
        case .accountNotConfigured:
            return L10n.text("账号尚未配置", "The mailbox is not configured.")
        case .invalidResponse:
            return L10n.text("邮箱服务返回了无法识别的数据", "The mail service returned unrecognized data.")
        case .server(let message):
            return message
        case .outlookNotInstalled:
            return L10n.text("未找到已安装的 Microsoft Outlook。", "Microsoft Outlook is not installed.")
        case .outlookAutomationDenied:
            return L10n.text(
                "无法读取 Outlook。请在“系统设置 → 隐私与安全性 → 自动化”中允许“邮件摘要”控制 Microsoft Outlook。",
                "Could not read Outlook. In System Settings > Privacy & Security > Automation, allow Mail Digest to control Microsoft Outlook."
            )
        case .outlookAccountMissing:
            return L10n.text(
                "没有找到对应的 Outlook 账号，请在设置中重新选择账号。",
                "The matching Outlook account was not found. Select it again in Settings."
            )
        }
    }
}

struct UnconfiguredMailService: MailSyncing {
    func fetchNewMessages(for account: MailAccount, since: Date) async throws -> [MailMessage] {
        throw MailServiceError.accountNotConfigured
    }
}

struct LiveMailService: MailSyncing {
    private let gmail: GmailAPIClient
    private let outlook: MicrosoftGraphAPIClient
    private let imap: IMAPMailClient

    init(tokens: OAuthTokenProvider = OAuthTokenProvider()) {
        gmail = GmailAPIClient(tokens: tokens)
        outlook = MicrosoftGraphAPIClient(tokens: tokens)
        imap = IMAPMailClient()
    }

    func fetchNewMessages(for account: MailAccount, since: Date) async throws -> [MailMessage] {
        switch account.provider {
        case .gmail:
            return try await gmail.fetchNewMessages(for: account, since: since)
        case .outlook:
            return try await outlook.fetchNewMessages(for: account, since: since)
        case .imap:
            return try await imap.fetchNewMessages(for: account, since: since)
        }
    }
}

actor OutlookAccountStore {
    private let defaults: UserDefaults
    private let keyPrefix = "outlook.local-account."

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func address(for accountID: String) -> String? {
        defaults.string(forKey: keyPrefix + accountID)
    }

    func setAddress(_ address: String?, for accountID: String) {
        let key = keyPrefix + accountID
        if let address, !address.isEmpty {
            defaults.set(address.lowercased(), forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }

    func autoConfigure(from accounts: [OutlookAccountInfo]) -> [String: String] {
        var result: [String: String] = [:]
        var unused = accounts

        for accountID in MailAccount.defaults.map(\.id) {
            if let saved = address(for: accountID),
               accounts.contains(where: { $0.email.caseInsensitiveCompare(saved) == .orderedSame }) {
                result[accountID] = saved
                unused.removeAll { $0.email.caseInsensitiveCompare(saved) == .orderedSame }
            }
        }

        func take(_ predicate: (OutlookAccountInfo) -> Bool) -> OutlookAccountInfo? {
            guard let index = unused.firstIndex(where: predicate) else { return nil }
            return unused.remove(at: index)
        }

        if result["gmail.school"] == nil,
           let account = take({ info in
               let email = info.email.lowercased()
               return email.hasSuffix(".edu") || email.contains(".edu.")
           }) {
            result["gmail.school"] = account.email.lowercased()
        }
        if result["outlook.private"] == nil,
           let account = take({ info in
               let email = info.email.lowercased()
               return email.hasSuffix("@outlook.com")
                   || email.hasSuffix("@hotmail.com")
                   || email.hasSuffix("@live.com")
           }) {
            result["outlook.private"] = account.email.lowercased()
        }
        if result["gmail.private"] == nil,
           let account = take({ $0.email.lowercased().hasSuffix("@gmail.com") }) {
            result["gmail.private"] = account.email.lowercased()
        }

        for accountID in MailAccount.defaults.map(\.id) where result[accountID] == nil {
            if let account = unused.first {
                unused.removeFirst()
                result[accountID] = account.email.lowercased()
            }
        }
        for (accountID, address) in result {
            setAddress(address, for: accountID)
        }
        return result
    }
}

struct OutlookLocalMailService: MailSyncing {
    let accountStore: OutlookAccountStore
    let automation: OutlookAutomation

    init(
        accountStore: OutlookAccountStore,
        automation: OutlookAutomation = OutlookAutomation()
    ) {
        self.accountStore = accountStore
        self.automation = automation
    }

    func fetchNewMessages(for account: MailAccount, since: Date) async throws -> [MailMessage] {
        guard let address = await accountStore.address(for: account.id) else {
            throw MailServiceError.accountNotConfigured
        }
        return try await automation.fetchMessages(
            accountID: account.id,
            accountAddress: address,
            since: since
        )
    }
}

actor DemoMailService: MailSyncing {
    private var deliveredAccounts = Set<String>()

    func fetchNewMessages(for account: MailAccount, since: Date) async throws -> [MailMessage] {
        guard !deliveredAccounts.contains(account.id) else { return [] }
        deliveredAccounts.insert(account.id)

        let calendar = Calendar.current
        switch account.id {
        case "gmail.school":
            return [
                MailMessage(
                    id: "demo-school-visa",
                    threadID: "demo-school-visa-thread",
                    accountID: account.id,
                    subject: "Action required: Update your iGlobal profile",
                    sender: "International Student Office",
                    receivedAt: .now.addingTimeInterval(-1_800),
                    bodyText: "Please submit your updated visa information in iGlobal before August 3.",
                    originalURL: URL(string: "https://mail.google.com/"),
                    attachments: []
                ),
                MailMessage(
                    id: "demo-school-library",
                    threadID: "demo-school-library-thread",
                    accountID: account.id,
                    subject: "Weekend library hours",
                    sender: "University Library",
                    receivedAt: .now.addingTimeInterval(-3_600),
                    bodyText: "Starting this weekend, the library will be open from 7:00 AM to 10:00 PM.",
                    originalURL: URL(string: "https://mail.google.com/"),
                    attachments: []
                )
            ]
        case "gmail.private":
            return [
                MailMessage(
                    id: "demo-private-flight",
                    threadID: "demo-private-flight-thread",
                    accountID: account.id,
                    subject: "Flight itinerary confirmation",
                    sender: "Travel Desk",
                    receivedAt: .now.addingTimeInterval(-7_200),
                    bodyText: "Your flight is confirmed. Please check in online 24 hours before departure.",
                    originalURL: URL(string: "https://mail.google.com/"),
                    attachments: []
                )
            ]
        default:
            let deadline = calendar.date(byAdding: .day, value: 5, to: .now)
            let formatted = deadline?.formatted(date: .abbreviated, time: .omitted) ?? "next week"
            return [
                MailMessage(
                    id: "demo-outlook-renewal",
                    threadID: "demo-outlook-renewal-thread",
                    accountID: account.id,
                    subject: "Subscription renewal reminder",
                    sender: "Membership Team",
                    receivedAt: .now.addingTimeInterval(-10_800),
                    bodyText: "Review your annual membership before \(formatted).",
                    originalURL: URL(string: "https://outlook.live.com/mail/"),
                    attachments: []
                )
            ]
        }
    }
}

struct DemoSummarizer: EmailSummarizing {
    func summarize(message: MailMessage, attachmentText: String) async throws -> [SummarizedAction] {
        if message.id.contains("visa") {
            let deadline = Calendar.current.date(from: DateComponents(year: 2026, month: 8, day: 3, hour: 23, minute: 59))
            return [SummarizedAction(
                actionKey: "submit-visa",
                summary: "8月3日之前需要在 iGlobal 上提交最新签证信息。",
                deadline: deadline,
                priority: .urgent,
                mailType: .actionRequired
            )]
        }
        if message.id.contains("library") {
            return [SummarizedAction(
                actionKey: "library-hours",
                summary: "学校图书馆周末开放时间调整为7:00至22:00。",
                deadline: nil,
                priority: .normal,
                mailType: .school
            )]
        }
        if message.id.contains("flight") {
            return [SummarizedAction(
                actionKey: "flight-check-in",
                summary: "航班起飞前24小时需要在线办理值机。",
                deadline: nil,
                priority: .important,
                mailType: .travel
            )]
        }
        return [SummarizedAction(
            actionKey: "review-renewal",
            summary: "需要在下周前检查年度会员续订信息。",
            deadline: Calendar.current.date(byAdding: .day, value: 5, to: .now),
            priority: .important,
            mailType: .finance
        )]
    }
}
