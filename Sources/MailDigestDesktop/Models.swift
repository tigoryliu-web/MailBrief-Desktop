import Foundation

enum MailProvider: String, Codable, CaseIterable, Sendable {
    case gmail
    case outlook
    case imap

    var displayName: String {
        switch self {
        case .gmail: "Gmail"
        case .outlook: "Outlook"
        case .imap: L10n.text("其他邮箱", "Other Mail")
        }
    }
}

struct IMAPConfiguration: Codable, Hashable, Sendable {
    var emailAddress: String
    var host: String
    var port: Int = 993
    var username: String
    var useTLS: Bool = true
}

struct MailAccount: Identifiable, Codable, Hashable, Sendable {
    let id: String
    var title: String
    var subtitle: String
    var provider: MailProvider
    var isConfigured: Bool
    var emailAddress: String? = nil
    var imapConfiguration: IMAPConfiguration? = nil

    static let defaults: [MailAccount] = [
        MailAccount(
            id: "gmail.private",
            title: "私人 Gmail",
            subtitle: "私人账号",
            provider: .gmail,
            isConfigured: false
        ),
        MailAccount(
            id: "gmail.school",
            title: "学校 Gmail",
            subtitle: "学校账号",
            provider: .gmail,
            isConfigured: false
        ),
        MailAccount(
            id: "outlook.private",
            title: "私人 Outlook",
            subtitle: "私人账号",
            provider: .outlook,
            isConfigured: false
        )
    ]
}

enum DigestPriority: String, Codable, CaseIterable, Sendable {
    case urgent
    case important
    case normal

    var displayName: String {
        switch self {
        case .urgent: L10n.text("紧急", "Urgent")
        case .important: L10n.text("重要", "Important")
        case .normal: L10n.text("普通", "Normal")
        }
    }

    var sortRank: Int {
        switch self {
        case .urgent: 0
        case .important: 1
        case .normal: 2
        }
    }
}

enum MailType: String, Codable, CaseIterable, Sendable {
    case actionRequired = "action_required"
    case school
    case finance
    case shopping
    case travel
    case newsletter
    case promotion
    case spamLowPriority = "spam_low_priority"
    case other

    var displayName: String {
        switch self {
        case .actionRequired: L10n.text("需要操作", "Action Required")
        case .school: L10n.text("学校", "School")
        case .finance: L10n.text("财务", "Finance")
        case .shopping: L10n.text("购物", "Shopping")
        case .travel: L10n.text("旅行", "Travel")
        case .newsletter: L10n.text("订阅通讯", "Newsletter")
        case .promotion: L10n.text("推广广告", "Promotion")
        case .spamLowPriority: L10n.text("垃圾／低优先级", "Spam / Low Priority")
        case .other: L10n.text("其他", "Other")
        }
    }
}

struct DigestItem: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var accountID: String
    var threadID: String
    var actionKey: String
    var summary: String
    var sender: String
    var receivedAt: Date
    var deadline: Date?
    var deadlineEnd: Date?
    var deadlineHasTime: Bool?
    var originalURL: String?
    var calendarEventIdentifier: String?
    var priority: DigestPriority
    var mailType: MailType?
    var suggestedPriority: DigestPriority
    var isCompleted: Bool
    var isNew: Bool
    var urgentNotificationSent: Bool
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        accountID: String,
        threadID: String,
        actionKey: String,
        summary: String,
        sender: String,
        receivedAt: Date,
        deadline: Date? = nil,
        deadlineEnd: Date? = nil,
        deadlineHasTime: Bool? = nil,
        originalURL: String? = nil,
        calendarEventIdentifier: String? = nil,
        priority: DigestPriority,
        mailType: MailType? = nil,
        suggestedPriority: DigestPriority? = nil,
        isCompleted: Bool = false,
        isNew: Bool = true,
        urgentNotificationSent: Bool = false,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.accountID = accountID
        self.threadID = threadID
        self.actionKey = actionKey
        self.summary = summary
        self.sender = sender
        self.receivedAt = receivedAt
        self.deadline = deadline
        self.deadlineEnd = deadlineEnd
        self.deadlineHasTime = deadlineHasTime
        self.originalURL = originalURL
        self.calendarEventIdentifier = calendarEventIdentifier
        self.priority = priority
        self.mailType = mailType
        self.suggestedPriority = suggestedPriority ?? priority
        self.isCompleted = isCompleted
        self.isNew = isNew
        self.urgentNotificationSent = urgentNotificationSent
        self.updatedAt = updatedAt
    }
}

enum AccountSyncStatus: Codable, Hashable, Sendable {
    case idle
    case refreshing
    case requiresSetup
    case failed(String)

    private enum CodingKeys: String, CodingKey {
        case kind
        case message
    }

    private enum Kind: String, Codable {
        case idle
        case refreshing
        case requiresSetup
        case failed
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .idle: self = .idle
        case .refreshing: self = .refreshing
        case .requiresSetup: self = .requiresSetup
        case .failed:
            self = .failed(try container.decode(String.self, forKey: .message))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .idle:
            try container.encode(Kind.idle, forKey: .kind)
        case .refreshing:
            try container.encode(Kind.refreshing, forKey: .kind)
        case .requiresSetup:
            try container.encode(Kind.requiresSetup, forKey: .kind)
        case .failed(let message):
            try container.encode(Kind.failed, forKey: .kind)
            try container.encode(message, forKey: .message)
        }
    }
}

struct AccountSection: Identifiable, Codable, Hashable, Sendable {
    var account: MailAccount
    var items: [DigestItem]
    var syncStatus: AccountSyncStatus
    var lastSuccessfulRefresh: Date?

    var id: String { account.id }
}

struct MailAttachment: Sendable {
    var filename: String
    var mimeType: String
    var data: Data
}

struct MailMessage: Sendable {
    var id: String
    var threadID: String
    var accountID: String
    var subject: String
    var sender: String
    var receivedAt: Date
    var bodyText: String
    var originalURL: URL?
    var attachments: [MailAttachment]
    var headers: [String: String] = [:]
}

struct OutlookAccountInfo: Identifiable, Hashable, Sendable {
    var id: String { email.lowercased() }
    var name: String
    var email: String

    var displayName: String {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedName.isEmpty || trimmedName.caseInsensitiveCompare(email) == .orderedSame
            ? email
            : "\(trimmedName)（\(email)）"
    }
}

struct SummarizedAction: Codable, Hashable, Sendable {
    var actionKey: String
    var summary: String
    var deadline: Date?
    var deadlineEnd: Date? = nil
    var deadlineHasTime: Bool = false
    var priority: DigestPriority
    var mailType: MailType? = nil
}

enum AppLanguage: String, Codable, CaseIterable, Sendable {
    case simplifiedChinese = "zh-Hans"
    case english = "en"

    var displayName: String {
        switch self {
        case .simplifiedChinese: "简体中文"
        case .english: "English"
        }
    }
}

struct ScheduledTime: Codable, Hashable, Comparable, Identifiable, Sendable {
    var minuteOfDay: Int

    var id: Int { minuteOfDay }
    var hour: Int { minuteOfDay / 60 }
    var minute: Int { minuteOfDay % 60 }

    init(hour: Int, minute: Int) {
        minuteOfDay = min(max(hour, 0), 23) * 60 + min(max(minute, 0), 59)
    }

    init(minuteOfDay: Int) {
        self.minuteOfDay = min(max(minuteOfDay, 0), 1_439)
    }

    static func < (lhs: ScheduledTime, rhs: ScheduledTime) -> Bool {
        lhs.minuteOfDay < rhs.minuteOfDay
    }

    var dateForPicker: Date {
        Calendar.current.date(from: DateComponents(hour: hour, minute: minute)) ?? .now
    }
}

struct AppSettings: Codable, Equatable, Sendable {
    var model: String = "gpt-5.6-terra"
    var launchAtLogin: Bool = true
    var maximumAttachmentBytes: Int = 20 * 1_024 * 1_024
    var language: AppLanguage = .simplifiedChinese
    var scheduledRefreshEnabled: Bool = false
    var scheduledTimes: [ScheduledTime] = []
    var accountModelVersion: Int = 2

    private enum CodingKeys: String, CodingKey {
        case model
        case launchAtLogin
        case maximumAttachmentBytes
        case language
        case scheduledRefreshEnabled
        case scheduledTimes
        case accountModelVersion
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        model = try container.decodeIfPresent(String.self, forKey: .model) ?? "gpt-5.6-terra"
        launchAtLogin = try container.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? true
        maximumAttachmentBytes = try container.decodeIfPresent(Int.self, forKey: .maximumAttachmentBytes)
            ?? 20 * 1_024 * 1_024
        language = try container.decodeIfPresent(AppLanguage.self, forKey: .language)
            ?? .simplifiedChinese
        scheduledRefreshEnabled = try container.decodeIfPresent(
            Bool.self,
            forKey: .scheduledRefreshEnabled
        ) ?? false
        let decodedTimes = try container.decodeIfPresent([ScheduledTime].self, forKey: .scheduledTimes) ?? []
        scheduledTimes = Array(Set(decodedTimes)).sorted().prefix(5).map { $0 }
        accountModelVersion = try container.decodeIfPresent(Int.self, forKey: .accountModelVersion) ?? 1
    }
}

struct PersistedSnapshot: Codable, Sendable {
    var sections: [AccountSection]
    var expandedAccountIDs: Set<String>
    var settings: AppSettings
    var lastRefresh: Date?
}

struct CalendarConflictPrompt: Identifiable, Equatable, Sendable {
    let id = UUID()
    var itemID: UUID
    var accountID: String
    var conflictingTitles: [String]

    var message: String {
        let separator = L10n.text("、", ", ")
        let visibleTitles = conflictingTitles.prefix(3).map { "“\($0)”" }.joined(separator: separator)
        if conflictingTitles.count <= 3 {
            return L10n.text(
                "与\(visibleTitles)冲突，是否依然添加？",
                "This conflicts with \(visibleTitles). Add it anyway?"
            )
        }
        return L10n.text(
            "与\(visibleTitles)等 \(conflictingTitles.count) 项安排冲突，是否依然添加？",
            "This conflicts with \(visibleTitles) and \(conflictingTitles.count - 3) more events. Add it anyway?"
        )
    }
}

enum RefreshTrigger: String, Sendable {
    case manual
    case retry
    case scheduled
}
