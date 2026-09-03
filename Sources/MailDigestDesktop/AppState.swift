import AppKit
import Foundation
import ServiceManagement
import SwiftUI

@MainActor
final class AppState: ObservableObject {
    @Published private(set) var sections: [AccountSection]
    @Published private(set) var isRefreshing = false
    @Published private(set) var lastRefresh: Date?
    @Published var expandedAccountIDs: Set<String>
    @Published private(set) var settings: AppSettings
    @Published private(set) var hasOpenAIKey = false
    @Published private(set) var hasGoogleOAuthClient = false
    @Published private(set) var hasMicrosoftClientID = false
    @Published private(set) var connectingAccountID: String?
    @Published private(set) var isPreviewing = false
    @Published private(set) var outlookAccounts: [OutlookAccountInfo] = []
    @Published private(set) var outlookAccountMappings: [String: String] = [:]
    @Published private(set) var isDetectingOutlook = false
    @Published private(set) var isAddingIMAPAccount = false
    @Published private(set) var calendarItemIDsAdding: Set<UUID> = []
    @Published private(set) var calendarErrors: [UUID: String] = [:]
    @Published var calendarConflictPrompt: CalendarConflictPrompt?
    @Published var settingsMessage: String?

    private let persistence: LocalPersistence
    private let keychain: KeychainStore
    private let attachmentExtractor: AttachmentTextExtractor
    private let notifications: DigestNotificationService
    private let oauthCoordinator: OAuthCoordinator
    private let mailService: any MailSyncing
    private let outlookAutomation: OutlookAutomation
    private let calendarService: AppleCalendarService
    private let imapClient: IMAPMailClient
    private let demoMode: Bool

    init(
        demoMode: Bool,
        persistence: LocalPersistence = .shared,
        keychain: KeychainStore = .shared,
        attachmentExtractor: AttachmentTextExtractor = AttachmentTextExtractor(),
        notifications: DigestNotificationService = DigestNotificationService(),
        calendarService: AppleCalendarService? = nil
    ) {
        self.demoMode = demoMode
        self.persistence = persistence
        self.keychain = keychain
        self.attachmentExtractor = attachmentExtractor
        self.notifications = notifications
        self.oauthCoordinator = OAuthCoordinator(keychain: keychain)
        self.outlookAutomation = OutlookAutomation()
        self.calendarService = calendarService ?? AppleCalendarService()
        self.imapClient = IMAPMailClient(keychain: keychain)
        self.mailService = demoMode
            ? DemoMailService()
            : LiveMailService()
        self.sections = MailAccount.defaults.map {
            AccountSection(
                account: $0,
                items: [],
                syncStatus: .requiresSetup,
                lastSuccessfulRefresh: nil
            )
        }
        self.expandedAccountIDs = []
        self.settings = AppSettings()
    }

    func start() async {
        var inferredLegacyDeadlines = false
        var migratedAccountModel = false
        if let snapshot = try? await persistence.load() {
            settings = snapshot.settings
            let isLegacyAccountModel = settings.accountModelVersion < 2
            migratedAccountModel = isLegacyAccountModel
            settings.accountModelVersion = 2
            lastRefresh = snapshot.lastRefresh
            expandedAccountIDs = snapshot.expandedAccountIDs
            sections = reconcile(snapshot.sections, includeMissingLegacyDefaults: isLegacyAccountModel)
            inferredLegacyDeadlines = inferMissingDeadlines()
        }
        L10n.language = settings.language
        updateLegacyDefaultAccountLabels(to: settings.language)

        if demoMode {
            for index in sections.indices {
                sections[index].account.isConfigured = true
                sections[index].syncStatus = .idle
            }
        }

        hasOpenAIKey = ((try? keychain.get(.openAI)) ?? nil)?.isEmpty == false
        hasGoogleOAuthClient = (try? keychain.get(.googleOAuthClient)) != nil
        hasMicrosoftClientID = ((try? keychain.get(.microsoftClientID)) ?? nil)?.isEmpty == false
        await notifications.requestAuthorization()

        if !demoMode { restoreOAuthAccountState() }

        if inferredLegacyDeadlines || migratedAccountModel {
            await persist()
        }

    }

    func refresh(trigger: RefreshTrigger, only accountID: String? = nil) async {
        guard !isRefreshing else { return }
        if trigger == .scheduled,
           RefreshSchedule.allAccountsWereRecentlyRefreshed(sections, at: .now) {
            return
        }
        isRefreshing = true
        defer { isRefreshing = false }

        let refreshDate = Date.now
        var totalNew = 0
        var urgentNew = 0
        var escalatedToUrgent = 0
        var anySuccessfulSection = false

        for index in sections.indices {
            if let accountID, sections[index].id != accountID { continue }

            guard sections[index].account.isConfigured || demoMode else {
                sections[index].syncStatus = .requiresSetup
                continue
            }

            sections[index].syncStatus = .refreshing
            let since = sections[index].lastSuccessfulRefresh
                ?? Calendar.current.date(byAdding: .hour, value: -24, to: refreshDate)!

            do {
                let messages = try await mailService.fetchNewMessages(
                    for: sections[index].account,
                    since: since
                )

                var workingItems = sections[index].items
                    .filter { !$0.isCompleted }
                    .map { item in
                        var copy = item
                        copy.isNew = false
                        return copy
                    }

                let recalculated = DigestMerger.recalculate(workingItems, now: refreshDate)
                workingItems = recalculated.items
                escalatedToUrgent += recalculated.newlyUrgent

                let summarizer: any EmailSummarizing = demoMode
                    ? DemoSummarizer()
                    : OpenAIEmailSummarizer(model: settings.model, language: settings.language)

                for message in messages.sorted(by: { $0.receivedAt < $1.receivedAt }) {
                    if PromotionFilter.shouldSkipBeforeSummarization(message) {
                        continue
                    }
                    let attachmentText = await extractAttachmentText(from: message.attachments)
                    let actions = try await summarizer.summarize(
                        message: message,
                        attachmentText: attachmentText
                    )
                    if PromotionFilter.shouldDiscard(actions) {
                        continue
                    }
                    let merged = DigestMerger.merge(
                        existing: workingItems,
                        accountID: sections[index].id,
                        message: message,
                        actions: actions,
                        now: refreshDate
                    )
                    workingItems = merged.items
                    totalNew += merged.insertedCount
                    urgentNew += actions.filter {
                        PriorityEngine.priority(
                            deadline: $0.deadline,
                            suggested: $0.priority,
                            now: refreshDate
                        ) == .urgent
                    }.count
                }

                sections[index].items = DigestMerger.sorted(workingItems)
                sections[index].lastSuccessfulRefresh = refreshDate
                sections[index].syncStatus = .idle
                anySuccessfulSection = true

                if !messages.isEmpty {
                    expandedAccountIDs.insert(sections[index].id)
                }
            } catch MailServiceError.accountNotConfigured {
                sections[index].syncStatus = .requiresSetup
            } catch {
                sections[index].syncStatus = .failed(error.localizedDescription)
            }
        }

        if anySuccessfulSection {
            lastRefresh = refreshDate
        }
        await persist()

        if trigger == .scheduled, urgentNew > 0 {
            await notifications.sendScheduledUrgentSummary(count: urgentNew)
        } else if trigger != .scheduled, totalNew > 0 {
            await notifications.sendRefreshSummary(newCount: totalNew, urgentCount: urgentNew)
        } else if trigger != .scheduled, escalatedToUrgent > 0 {
            await notifications.sendUrgencyEscalation(count: escalatedToUrgent)
        }
    }

    func toggleCompletion(itemID: UUID, accountID: String) {
        guard let sectionIndex = sections.firstIndex(where: { $0.id == accountID }),
              let itemIndex = sections[sectionIndex].items.firstIndex(where: { $0.id == itemID })
        else { return }

        sections[sectionIndex].items[itemIndex].isCompleted.toggle()
        sections[sectionIndex].items = DigestMerger.sorted(sections[sectionIndex].items)
        Task { await persist() }
    }

    func toggleExpanded(accountID: String) {
        if expandedAccountIDs.contains(accountID) {
            expandedAccountIDs.remove(accountID)
        } else {
            expandedAccountIDs.insert(accountID)
        }
        Task { await persist() }
    }

    func retry(accountID: String) {
        Task { await refresh(trigger: .retry, only: accountID) }
    }

    func sendTestNotification() {
        Task { await notifications.sendTestNotification() }
    }

    func addToCalendar(itemID: UUID, accountID: String) async {
        guard let item = calendarItem(itemID: itemID, accountID: accountID),
              item.calendarEventIdentifier == nil,
              !calendarItemIDsAdding.contains(itemID)
        else { return }

        calendarErrors[itemID] = nil
        calendarItemIDsAdding.insert(itemID)
        do {
            let conflicts = try await calendarService.conflicts(for: item)
            calendarItemIDsAdding.remove(itemID)
            if conflicts.isEmpty {
                try await saveCalendarEvent(for: itemID, accountID: accountID)
            } else {
                calendarConflictPrompt = CalendarConflictPrompt(
                    itemID: itemID,
                    accountID: accountID,
                    conflictingTitles: conflicts.map(\.title)
                )
            }
        } catch {
            calendarItemIDsAdding.remove(itemID)
            calendarErrors[itemID] = error.localizedDescription
        }
    }

    func confirmCalendarConflict(_ prompt: CalendarConflictPrompt) async {
        calendarConflictPrompt = nil
        do {
            try await saveCalendarEvent(for: prompt.itemID, accountID: prompt.accountID)
        } catch {
            calendarItemIDsAdding.remove(prompt.itemID)
            calendarErrors[prompt.itemID] = error.localizedDescription
        }
    }

    func cancelCalendarConflict() {
        calendarConflictPrompt = nil
    }

    func openOriginal(_ item: DigestItem) {
        guard let value = item.originalURL, let url = URL(string: value) else { return }
        if OriginalMessageRouter.route(for: url) == .outlookAutomation,
           let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
           let account = components.queryItems?.first(where: { $0.name == "account" })?.value,
           let messageID = components.queryItems?.first(where: { $0.name == "id" })?.value {
            Task {
                do {
                    try await outlookAutomation.openMessage(
                        accountAddress: account,
                        messageID: messageID
                    )
                } catch {
                    settingsMessage = error.localizedDescription
                }
            }
            return
        }
        // Gmail and Microsoft Graph both provide HTTPS web links. Let macOS
        // route those through the user's default browser instead of forcing
        // them into Outlook, which can try to launch a second Outlook process.
        NSWorkspace.shared.open(url)
    }

    func saveAPIKey(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            settingsMessage = L10n.text("请输入 API 密钥。", "Enter an API key.")
            return
        }
        do {
            try keychain.set(trimmed, for: .openAI)
            hasOpenAIKey = true
            settingsMessage = L10n.text(
                "OpenAI 密钥已安全保存到 macOS 钥匙串。",
                "The OpenAI key was saved securely in macOS Keychain."
            )
        } catch {
            settingsMessage = error.localizedDescription
        }
    }

    func deleteAPIKey() {
        do {
            try keychain.delete(.openAI)
            hasOpenAIKey = false
            settingsMessage = L10n.text(
                "OpenAI 密钥已从钥匙串删除。",
                "The OpenAI key was deleted from Keychain."
            )
        } catch {
            settingsMessage = error.localizedDescription
        }
    }

    func setModel(_ model: String) {
        settings.model = model
        Task { await persist() }
    }

    func setLanguage(_ language: AppLanguage) {
        settings.language = language
        L10n.language = language
        updateLegacyDefaultAccountLabels(to: language)
        settingsMessage = L10n.text("应用语言已更新。", "The application language was updated.")
        AppCommands.refreshMenus()
        Task { await persist() }
    }

    func setScheduledRefreshEnabled(_ enabled: Bool) {
        settings.scheduledRefreshEnabled = enabled
        settingsMessage = enabled
            ? L10n.text("已启用定时刷新。", "Scheduled refresh is enabled.")
            : L10n.text("已暂停定时刷新，设置的时间已保留。", "Scheduled refresh is paused; its times were preserved.")
        Task { await persist() }
    }

    func addScheduledTime(_ date: Date) {
        let components = Calendar.current.dateComponents([.hour, .minute], from: date)
        let time = ScheduledTime(hour: components.hour ?? 0, minute: components.minute ?? 0)
        guard !settings.scheduledTimes.contains(time) else {
            settingsMessage = L10n.text("这个刷新时间已经存在。", "That refresh time already exists.")
            return
        }
        guard settings.scheduledTimes.count < 5 else {
            settingsMessage = L10n.text("最多可以设置5个刷新时间。", "You can set up to five refresh times.")
            return
        }
        settings.scheduledTimes = RefreshSchedule.normalized(settings.scheduledTimes + [time])
        Task { await persist() }
    }

    func updateScheduledTime(_ oldTime: ScheduledTime, to date: Date) {
        let components = Calendar.current.dateComponents([.hour, .minute], from: date)
        let replacement = ScheduledTime(hour: components.hour ?? 0, minute: components.minute ?? 0)
        var values = settings.scheduledTimes.filter { $0 != oldTime }
        values.append(replacement)
        settings.scheduledTimes = RefreshSchedule.normalized(values)
        Task { await persist() }
    }

    func removeScheduledTime(_ time: ScheduledTime) {
        settings.scheduledTimes.removeAll { $0 == time }
        Task { await persist() }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            settings.launchAtLogin = enabled
            settingsMessage = enabled
                ? L10n.text("已开启登录时启动。", "Launch at login is enabled.")
                : L10n.text("已关闭登录时启动。", "Launch at login is disabled.")
            Task { await persist() }
        } catch {
            settingsMessage = L10n.text(
                "无法修改开机启动：\(error.localizedDescription)",
                "Could not change launch at login: \(error.localizedDescription)"
            )
        }
    }

    func saveGoogleOAuthClient(clientID: String, clientSecret: String) {
        let id = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        let secret = clientSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty, !secret.isEmpty else {
            settingsMessage = L10n.text(
                "Google 客户端 ID 和客户端密钥都不能为空。",
                "Google Client ID and Client Secret are both required."
            )
            return
        }
        do {
            try keychain.setCodable(
                GoogleOAuthClient(clientID: id, clientSecret: secret),
                for: .googleOAuthClient
            )
            hasGoogleOAuthClient = true
            settingsMessage = L10n.text(
                "Google OAuth 客户端信息已保存到钥匙串。",
                "Google OAuth client settings were saved to Keychain."
            )
        } catch {
            settingsMessage = error.localizedDescription
        }
    }

    func saveMicrosoftClientID(_ value: String) {
        let id = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else {
            settingsMessage = L10n.text(
                "Microsoft 客户端 ID 不能为空。",
                "Microsoft Client ID is required."
            )
            return
        }
        do {
            try keychain.set(id, for: .microsoftClientID)
            hasMicrosoftClientID = true
            settingsMessage = L10n.text(
                "Microsoft 客户端 ID 已保存到钥匙串。",
                "Microsoft Client ID was saved to Keychain."
            )
        } catch {
            settingsMessage = error.localizedDescription
        }
    }

    @discardableResult
    func connect(_ account: MailAccount) async -> Bool {
        guard account.provider != .imap else { return false }
        guard connectingAccountID == nil else { return false }
        connectingAccountID = account.id
        settingsMessage = L10n.text(
            "请在浏览器中登录并批准 \(account.title) 的只读访问。",
            "Sign in with your browser and approve read-only access for \(account.title)."
        )
        defer { connectingAccountID = nil }

        do {
            let tokens = try await oauthCoordinator.authorize(account)
            guard let index = sections.firstIndex(where: { $0.id == account.id }) else { return false }
            let email = tokens.accountEmail?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if let email, duplicateAccount(provider: account.provider, emailAddress: email, excluding: account.id) != nil {
                try? keychain.delete(account: SecretKey.tokenAccount(for: account.id))
                settingsMessage = L10n.text(
                    "这个邮箱已经添加。",
                    "This mailbox has already been added."
                )
                return false
            }
            sections[index].account.isConfigured = true
            sections[index].account.emailAddress = email
            sections[index].account.subtitle = email ?? account.subtitle
            if !MailAccount.defaults.contains(where: { $0.id == account.id }), let email {
                sections[index].account.title = email
            }
            sections[index].syncStatus = .idle
            settingsMessage = L10n.text("邮箱已连接。", "Mailbox connected.")
            await persist()
            await refresh(trigger: .manual, only: account.id)
            return true
        } catch {
            settingsMessage = error.localizedDescription
            return false
        }
    }

    func disconnect(_ account: MailAccount) {
        do {
            switch account.provider {
            case .gmail, .outlook:
                try keychain.delete(account: SecretKey.tokenAccount(for: account.id))
            case .imap:
                try keychain.delete(account: SecretKey.imapPasswordAccount(for: account.id))
            }
            guard let index = sections.firstIndex(where: { $0.id == account.id }) else { return }
            sections[index].account.isConfigured = false
            sections[index].syncStatus = .requiresSetup
            settingsMessage = L10n.text("\(account.title) 已断开。", "\(account.title) was disconnected.")
            Task { await persist() }
        } catch {
            settingsMessage = error.localizedDescription
        }
    }

    func addOAuthAccount(provider: MailProvider) async {
        guard provider == .gmail || provider == .outlook else { return }
        guard sections.count < 5 else {
            settingsMessage = L10n.text("最多可以添加5个邮箱。", "You can add up to five mailboxes.")
            return
        }
        if provider == .gmail, !hasGoogleOAuthClient {
            settingsMessage = L10n.text("请先在设置中保存 Google OAuth 客户端信息。", "Save the Google OAuth client in Settings first.")
            AppCommands.openSettings()
            return
        }
        if provider == .outlook, !hasMicrosoftClientID {
            settingsMessage = L10n.text("请先在设置中保存 Microsoft 客户端 ID。", "Save the Microsoft client ID in Settings first.")
            AppCommands.openSettings()
            return
        }

        let id = "\(provider.rawValue).\(UUID().uuidString.lowercased())"
        let account = MailAccount(
            id: id,
            title: L10n.accountDefaultTitle(provider: provider),
            subtitle: L10n.text("正在连接…", "Connecting…"),
            provider: provider,
            isConfigured: false
        )
        sections.append(AccountSection(
            account: account,
            items: [],
            syncStatus: .requiresSetup,
            lastSuccessfulRefresh: nil
        ))
        if !(await connect(account)) {
            sections.removeAll { $0.id == id }
            expandedAccountIDs.remove(id)
            try? keychain.delete(account: SecretKey.tokenAccount(for: id))
            await persist()
        }
    }

    @discardableResult
    func addIMAPAccount(configuration: IMAPConfiguration, password: String) async -> Bool {
        guard !isAddingIMAPAccount else { return false }
        guard sections.count < 5 else {
            settingsMessage = L10n.text("最多可以添加5个邮箱。", "You can add up to five mailboxes.")
            return false
        }
        var normalized = configuration
        normalized.emailAddress = configuration.emailAddress.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        normalized.host = configuration.host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        normalized.username = configuration.username.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanPassword = password.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.emailAddress.isEmpty, !normalized.host.isEmpty,
              !normalized.username.isEmpty, !cleanPassword.isEmpty
        else {
            settingsMessage = L10n.text("请填写完整的 IMAP 配置。", "Complete all IMAP settings.")
            return false
        }
        guard duplicateAccount(provider: .imap, emailAddress: normalized.emailAddress) == nil else {
            settingsMessage = L10n.text("这个邮箱已经添加。", "This mailbox has already been added.")
            return false
        }

        isAddingIMAPAccount = true
        defer { isAddingIMAPAccount = false }
        do {
            try await imapClient.test(configuration: normalized, password: cleanPassword)
            let id = "imap.\(UUID().uuidString.lowercased())"
            try keychain.set(cleanPassword, account: SecretKey.imapPasswordAccount(for: id))
            let account = MailAccount(
                id: id,
                title: normalized.emailAddress,
                subtitle: normalized.emailAddress,
                provider: .imap,
                isConfigured: true,
                emailAddress: normalized.emailAddress,
                imapConfiguration: normalized
            )
            sections.append(AccountSection(
                account: account,
                items: [],
                syncStatus: .idle,
                lastSuccessfulRefresh: nil
            ))
            settingsMessage = L10n.text("IMAP 邮箱已连接。", "IMAP mailbox connected.")
            await persist()
            await refresh(trigger: .manual, only: id)
            return true
        } catch {
            settingsMessage = error.localizedDescription
            return false
        }
    }

    @discardableResult
    func configureIMAPAccount(
        id: String,
        configuration: IMAPConfiguration,
        password: String
    ) async -> Bool {
        guard !isAddingIMAPAccount,
              let index = sections.firstIndex(where: { $0.id == id && $0.account.provider == .imap })
        else { return false }
        var normalized = configuration
        normalized.emailAddress = configuration.emailAddress.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        normalized.host = configuration.host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        normalized.username = configuration.username.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanPassword = password.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.emailAddress.isEmpty, !normalized.host.isEmpty,
              !normalized.username.isEmpty, !cleanPassword.isEmpty,
              duplicateAccount(provider: .imap, emailAddress: normalized.emailAddress, excluding: id) == nil
        else {
            settingsMessage = L10n.text("IMAP 配置不完整或邮箱已经存在。", "The IMAP settings are incomplete or the mailbox already exists.")
            return false
        }
        isAddingIMAPAccount = true
        defer { isAddingIMAPAccount = false }
        do {
            try await imapClient.test(configuration: normalized, password: cleanPassword)
            try keychain.set(cleanPassword, account: SecretKey.imapPasswordAccount(for: id))
            sections[index].account.emailAddress = normalized.emailAddress
            sections[index].account.subtitle = normalized.emailAddress
            sections[index].account.imapConfiguration = normalized
            sections[index].account.isConfigured = true
            sections[index].syncStatus = .idle
            settingsMessage = L10n.text("IMAP 邮箱配置已更新。", "IMAP mailbox settings updated.")
            await persist()
            await refresh(trigger: .manual, only: id)
            return true
        } catch {
            settingsMessage = error.localizedDescription
            return false
        }
    }

    func renameAccount(id: String, title: String) {
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, let index = sections.firstIndex(where: { $0.id == id }) else { return }
        sections[index].account.title = clean
        Task { await persist() }
    }

    func moveAccounts(fromOffsets: IndexSet, toOffset: Int) {
        sections.move(fromOffsets: fromOffsets, toOffset: toOffset)
        Task { await persist() }
    }

    func moveAccount(id: String, direction: Int) {
        guard let index = sections.firstIndex(where: { $0.id == id }) else { return }
        let destination = index + direction
        guard sections.indices.contains(destination) else { return }
        sections.swapAt(index, destination)
        Task { await persist() }
    }

    func removeAccount(_ account: MailAccount) {
        do {
            try? keychain.delete(account: SecretKey.tokenAccount(for: account.id))
            try? keychain.delete(account: SecretKey.imapPasswordAccount(for: account.id))
            sections.removeAll { $0.id == account.id }
            expandedAccountIDs.remove(account.id)
            settingsMessage = L10n.text("已从本机移除 \(account.title)。", "Removed \(account.title) from this Mac.")
            Task { await persist() }
        }
    }

    private func duplicateAccount(
        provider: MailProvider,
        emailAddress: String,
        excluding accountID: String? = nil
    ) -> MailAccount? {
        let normalized = emailAddress.lowercased()
        return sections.lazy.map(\.account).first {
            $0.id != accountID
                && ($0.emailAddress ?? $0.subtitle).lowercased() == normalized
        }
    }

    func loadPreviewData() {
        isPreviewing = true
        let now = Date.now
        let sampleItems: [String: [DigestItem]] = [
            "gmail.private": [
                DigestItem(
                    accountID: "gmail.private",
                    threadID: "preview-flight",
                    actionKey: "online-check-in",
                    summary: "航班起飞前24小时需要在线办理值机。",
                    sender: "Travel Desk",
                    receivedAt: now.addingTimeInterval(-7_200),
                    priority: .important,
                    mailType: .travel
                )
            ],
            "gmail.school": [
                DigestItem(
                    accountID: "gmail.school",
                    threadID: "preview-visa",
                    actionKey: "submit-visa",
                    summary: "8月3日之前需要在 iGlobal 上提交最新签证信息。",
                    sender: "International Student Office",
                    receivedAt: now.addingTimeInterval(-1_800),
                    deadline: Calendar.current.date(from: DateComponents(
                        year: 2026,
                        month: 8,
                        day: 3,
                        hour: 23,
                        minute: 59
                    )),
                    priority: .urgent,
                    mailType: .actionRequired
                ),
                DigestItem(
                    accountID: "gmail.school",
                    threadID: "preview-library",
                    actionKey: "library-hours",
                    summary: "学校图书馆周末开放时间调整为7:00至22:00。",
                    sender: "University Library",
                    receivedAt: now.addingTimeInterval(-3_600),
                    priority: .normal,
                    mailType: .school
                )
            ],
            "outlook.private": [
                DigestItem(
                    accountID: "outlook.private",
                    threadID: "preview-membership",
                    actionKey: "review-renewal",
                    summary: "需要在下周前检查年度会员续订信息。",
                    sender: "Membership Team",
                    receivedAt: now.addingTimeInterval(-10_800),
                    deadline: Calendar.current.date(byAdding: .day, value: 5, to: now),
                    priority: .important,
                    mailType: .finance
                )
            ]
        ]

        for index in sections.indices {
            sections[index].items = sampleItems[sections[index].id] ?? []
            sections[index].syncStatus = .idle
        }
        expandedAccountIDs = Set(sections.map(\.id))
        lastRefresh = now
    }

    func clearPreviewData() {
        guard isPreviewing else { return }
        isPreviewing = false
        for index in sections.indices {
            sections[index].items = []
            sections[index].syncStatus = sections[index].account.isConfigured ? .idle : .requiresSetup
        }
        expandedAccountIDs = []
        lastRefresh = nil
    }

    private func extractAttachmentText(from attachments: [MailAttachment]) async -> String {
        var extracted: [String] = []
        for attachment in attachments {
            do {
                let text = try await attachmentExtractor.extractText(
                    from: attachment,
                    maximumBytes: settings.maximumAttachmentBytes
                )
                extracted.append(L10n.text(
                    "附件 \(attachment.filename)：\n\(text)",
                    "Attachment \(attachment.filename):\n\(text)"
                ))
            } catch {
                continue
            }
        }
        return extracted.joined(separator: "\n\n")
    }

    private func calendarItem(itemID: UUID, accountID: String) -> DigestItem? {
        sections.first(where: { $0.id == accountID })?
            .items.first(where: { $0.id == itemID })
    }

    private func inferMissingDeadlines() -> Bool {
        var changed = false
        for sectionIndex in sections.indices {
            for itemIndex in sections[sectionIndex].items.indices {
                guard let parsed = SummaryDeadlineParser.parse(
                        sections[sectionIndex].items[itemIndex].summary,
                        referenceDate: sections[sectionIndex].items[itemIndex].receivedAt
                      )
                else { continue }

                if sections[sectionIndex].items[itemIndex].deadline == nil {
                    sections[sectionIndex].items[itemIndex].deadline = parsed.date
                    sections[sectionIndex].items[itemIndex].deadlineHasTime = parsed.hasSpecificTime
                    sections[sectionIndex].items[itemIndex].priority = PriorityEngine.priority(
                        deadline: parsed.date,
                        suggested: sections[sectionIndex].items[itemIndex].suggestedPriority
                    )
                    changed = true
                }
                if sections[sectionIndex].items[itemIndex].deadlineEnd == nil,
                   let parsedEnd = parsed.endDate {
                    sections[sectionIndex].items[itemIndex].deadlineEnd = parsedEnd
                    changed = true
                }
            }
            sections[sectionIndex].items = DigestMerger.sorted(sections[sectionIndex].items)
        }
        return changed
    }

    private func saveCalendarEvent(for itemID: UUID, accountID: String) async throws {
        guard let item = calendarItem(itemID: itemID, accountID: accountID),
              item.calendarEventIdentifier == nil
        else { return }

        calendarItemIDsAdding.insert(itemID)
        calendarErrors[itemID] = nil
        let identifier = try await calendarService.add(item)

        guard let sectionIndex = sections.firstIndex(where: { $0.id == accountID }),
              let itemIndex = sections[sectionIndex].items.firstIndex(where: { $0.id == itemID })
        else {
            calendarItemIDsAdding.remove(itemID)
            return
        }
        sections[sectionIndex].items[itemIndex].calendarEventIdentifier = identifier
        calendarItemIDsAdding.remove(itemID)
        settingsMessage = L10n.text("已添加到 Apple 日历。", "Added to Apple Calendar.")
        await persist()
    }

    private func updateLegacyDefaultAccountLabels(to language: AppLanguage) {
        for index in sections.indices {
            let id = sections[index].id
            let knownTitles = AppLanguage.allCases.compactMap {
                L10n.legacyAccountTitle(id: id, language: $0)
            }
            if knownTitles.contains(sections[index].account.title),
               let localized = L10n.legacyAccountTitle(id: id, language: language) {
                sections[index].account.title = localized
            }

            guard sections[index].account.emailAddress == nil else { continue }
            let knownSubtitles = AppLanguage.allCases.compactMap {
                L10n.legacyAccountSubtitle(id: id, language: $0)
            }
            if knownSubtitles.contains(sections[index].account.subtitle),
               let localized = L10n.legacyAccountSubtitle(id: id, language: language) {
                sections[index].account.subtitle = localized
            }
        }
    }

    private func reconcile(
        _ saved: [AccountSection],
        includeMissingLegacyDefaults: Bool
    ) -> [AccountSection] {
        var result = saved
        if includeMissingLegacyDefaults {
            for account in MailAccount.defaults where !result.contains(where: { $0.id == account.id }) {
                result.append(AccountSection(
                    account: account,
                    items: [],
                    syncStatus: .requiresSetup,
                    lastSuccessfulRefresh: nil
                ))
            }
        }
        return result.prefix(5).map { savedSection in
            var section = savedSection
            if section.account.emailAddress == nil,
               section.account.isConfigured,
               !section.account.subtitle.isEmpty {
                section.account.emailAddress = section.account.subtitle.lowercased()
            }
            if !section.account.isConfigured {
                section.syncStatus = .requiresSetup
            } else if case .refreshing = section.syncStatus {
                section.syncStatus = .idle
            }
            return section
        }
    }

    private func restoreOAuthAccountState() {
        for index in sections.indices {
            let account = sections[index].account
            let secretExists: Bool
            switch account.provider {
            case .gmail, .outlook:
                secretExists = ((try? keychain.get(
                    account: SecretKey.tokenAccount(for: account.id)
                )) ?? nil) != nil
            case .imap:
                secretExists = account.imapConfiguration != nil
                    && ((try? keychain.get(
                        account: SecretKey.imapPasswordAccount(for: account.id)
                    )) ?? nil) != nil
            }
            guard secretExists else {
                sections[index].account.isConfigured = false
                sections[index].syncStatus = .requiresSetup
                continue
            }
            sections[index].account.isConfigured = true
            if account.provider != .imap,
               let tokens = try? keychain.getCodable(
                    OAuthTokenSet.self,
                    account: SecretKey.tokenAccount(for: account.id)
               ), let email = tokens.accountEmail, !email.isEmpty {
                sections[index].account.subtitle = email.lowercased()
                sections[index].account.emailAddress = email.lowercased()
            }
            if case .refreshing = sections[index].syncStatus {
                sections[index].syncStatus = .idle
            }
        }
    }

    private func persist() async {
        guard !isPreviewing else { return }
        let snapshot = PersistedSnapshot(
            sections: sections,
            expandedAccountIDs: expandedAccountIDs,
            settings: settings,
            lastRefresh: lastRefresh
        )
        try? await persistence.save(snapshot)
    }
}

enum OriginalMessageRoute: Equatable {
    case outlookAutomation
    case systemDefault
}

enum OriginalMessageRouter {
    static func route(for url: URL) -> OriginalMessageRoute {
        url.scheme?.lowercased() == "maildigest-outlook"
            ? .outlookAutomation
            : .systemDefault
    }
}
