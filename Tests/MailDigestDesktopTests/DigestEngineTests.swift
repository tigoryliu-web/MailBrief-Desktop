import XCTest
@testable import MailDigestDesktop

final class DigestEngineTests: XCTestCase {
    func testDeadlineWithinOneDayIsUrgent() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let deadline = now.addingTimeInterval(23 * 60 * 60)

        XCTAssertEqual(
            PriorityEngine.priority(deadline: deadline, suggested: .normal, now: now),
            .urgent
        )
    }

    func testDeadlineWithinThreeDaysIsImportant() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let deadline = now.addingTimeInterval(60 * 60 * 60)

        XCTAssertEqual(
            PriorityEngine.priority(deadline: deadline, suggested: .normal, now: now),
            .important
        )
    }

    func testThreadReplyReplacesOldActionsAndResetsCompletion() {
        let old = DigestItem(
            accountID: "gmail.school",
            threadID: "thread-1",
            actionKey: "old-action",
            summary: "旧摘要",
            sender: "学校",
            receivedAt: .distantPast,
            priority: .normal,
            isCompleted: true,
            isNew: false
        )
        let message = MailMessage(
            id: "message-2",
            threadID: "thread-1",
            accountID: "gmail.school",
            subject: "更新",
            sender: "学校",
            receivedAt: .now,
            bodyText: "更新后的内容",
            originalURL: URL(string: "https://mail.google.com/"),
            attachments: []
        )
        let action = SummarizedAction(
            actionKey: "new-action",
            summary: "新摘要",
            deadline: nil,
            priority: .important
        )

        let result = DigestMerger.merge(
            existing: [old],
            accountID: "gmail.school",
            message: message,
            actions: [action]
        )

        XCTAssertEqual(result.items.count, 1)
        XCTAssertEqual(result.items.first?.summary, "新摘要")
        XCTAssertEqual(result.items.first?.isCompleted, false)
        XCTAssertEqual(result.items.first?.isNew, true)
    }

    func testLegacySettingsDecodeAfterAutomaticRefreshRemoval() throws {
        let data = Data(#"{"model":"gpt-5.6-terra","scheduledHours":[8,14,20],"launchAtLogin":true,"maximumAttachmentBytes":20971520}"#.utf8)
        let settings = try JSONDecoder().decode(AppSettings.self, from: data)

        XCTAssertEqual(settings.model, "gpt-5.6-terra")
        XCTAssertTrue(settings.launchAtLogin)
        XCTAssertEqual(settings.maximumAttachmentBytes, 20 * 1_024 * 1_024)
        XCTAssertEqual(settings.language, .simplifiedChinese)
        XCTAssertFalse(settings.scheduledRefreshEnabled)
        XCTAssertEqual(settings.scheduledTimes, [])
        XCTAssertEqual(settings.accountModelVersion, 1)
    }

    func testScheduleNormalizesSortsDeduplicatesAndCapsAtFive() {
        let result = RefreshSchedule.normalized([
            ScheduledTime(hour: 18, minute: 30),
            ScheduledTime(hour: 8, minute: 0),
            ScheduledTime(hour: 12, minute: 15),
            ScheduledTime(hour: 8, minute: 0),
            ScheduledTime(hour: 7, minute: 45),
            ScheduledTime(hour: 21, minute: 0),
            ScheduledTime(hour: 23, minute: 0)
        ])

        XCTAssertEqual(result.map(\.minuteOfDay), [465, 480, 735, 1_110, 1_260])
    }

    func testScheduleMatchesOnlyEnabledExactMinute() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let date = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026, month: 9, day: 2, hour: 8, minute: 30, second: 42
        )))
        let times = [ScheduledTime(hour: 8, minute: 30)]

        XCTAssertNil(RefreshSchedule.scheduledTime(at: date, enabled: false, times: times, calendar: calendar))
        XCTAssertEqual(
            RefreshSchedule.scheduledTime(at: date, enabled: true, times: times, calendar: calendar),
            ScheduledTime(hour: 8, minute: 30)
        )
    }

    func testRecentRefreshSkipRequiresEveryConnectedAccount() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let recent = AccountSection(
            account: MailAccount(
                id: "one", title: "One", subtitle: "one@example.com",
                provider: .imap, isConfigured: true
            ),
            items: [], syncStatus: .idle, lastSuccessfulRefresh: now.addingTimeInterval(-60)
        )
        var stale = recent
        stale.account = MailAccount(
            id: "two", title: "Two", subtitle: "two@example.com",
            provider: .imap, isConfigured: true
        )
        stale.lastSuccessfulRefresh = now.addingTimeInterval(-16 * 60)

        XCTAssertTrue(RefreshSchedule.allAccountsWereRecentlyRefreshed([recent], at: now))
        XCTAssertFalse(RefreshSchedule.allAccountsWereRecentlyRefreshed([recent, stale], at: now))
    }

    func testMailTypeIsStoredOnNewDigestItems() {
        let message = MailMessage(
            id: "message-type", threadID: "thread-type", accountID: "gmail.school",
            subject: "Tuition", sender: "University", receivedAt: .now,
            bodyText: "Pay tuition.", originalURL: nil, attachments: []
        )
        let action = SummarizedAction(
            actionKey: "pay-tuition", summary: "Pay tuition.", deadline: nil,
            priority: .important, mailType: .finance
        )

        let item = DigestMerger.merge(
            existing: [], accountID: message.accountID, message: message, actions: [action]
        ).items.first

        XCTAssertEqual(item?.mailType, .finance)
    }

    func testLegacyDigestWithoutMailTypeStillDecodes() throws {
        let item = DigestItem(
            accountID: "gmail.private", threadID: "legacy", actionKey: "read",
            summary: "Legacy", sender: "Sender", receivedAt: .now, priority: .normal
        )
        let data = try JSONEncoder().encode(item)
        XCTAssertNil(try JSONDecoder().decode(DigestItem.self, from: data).mailType)
    }

    func testIMAPPresetsUseEncryptedStandardPort() {
        let iCloud = IMAPPreset.configuration(for: "Person@icloud.com")
        XCTAssertEqual(iCloud.emailAddress, "person@icloud.com")
        XCTAssertEqual(iCloud.host, "imap.mail.me.com")
        XCTAssertEqual(iCloud.port, 993)
        XCTAssertTrue(iCloud.useTLS)

        XCTAssertEqual(
            IMAPPreset.configuration(for: "person@example.com").host,
            "imap.example.com"
        )
    }

    func testRawIMAPEmailParserReadsBasicMessage() throws {
        let raw = Data("""
        Message-ID: <abc@example.com>\r
        Subject: Hello\r
        From: Sender <sender@example.com>\r
        Date: Wed, 2 Sep 2026 08:30:00 -0700\r
        Content-Type: text/plain; charset=utf-8\r
        \r
        This is the body.\r
        """.utf8)

        let parsed = try XCTUnwrap(RawEmailParser.parse(raw))
        XCTAssertEqual(parsed.messageID, "abc@example.com")
        XCTAssertEqual(parsed.subject, "Hello")
        XCTAssertTrue(parsed.body.contains("This is the body."))
        XCTAssertEqual(parsed.headers["message-id"], "<abc@example.com>")
    }

    func testGmailSearchExcludesPromotionsBeforeDownload() {
        let since = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertEqual(
            GmailAPIClient.searchQuery(since: since),
            "after:1800000000 -category:promotions"
        )
    }

    func testBulkCommercialEmailIsSkippedBeforeOpenAI() {
        let message = MailMessage(
            id: "promo", threadID: "promo", accountID: "imap-one",
            subject: "Limited time: 40% off", sender: "Store", receivedAt: .now,
            bodyText: "Shop now.", originalURL: nil, attachments: [],
            headers: ["List-Unsubscribe": "<mailto:unsubscribe@example.com>"]
        )

        XCTAssertTrue(PromotionFilter.shouldSkipBeforeSummarization(message))
    }

    func testTransactionalEmailWithListHeaderIsNotSkipped() {
        let message = MailMessage(
            id: "receipt", threadID: "receipt", accountID: "imap-one",
            subject: "Your order receipt", sender: "Store", receivedAt: .now,
            bodyText: "Your order has shipped.", originalURL: nil, attachments: [],
            headers: ["List-Unsubscribe": "<mailto:unsubscribe@example.com>"]
        )

        XCTAssertFalse(PromotionFilter.shouldSkipBeforeSummarization(message))
    }

    func testAIPromotionResultIsDiscarded() {
        let action = SummarizedAction(
            actionKey: "promotion", summary: "限时促销。", deadline: nil,
            priority: .normal, mailType: .promotion
        )

        XCTAssertTrue(PromotionFilter.shouldDiscard([action]))
    }

    func testDynamicOAuthTokenKeysDoNotOverwriteLegacyKeys() {
        XCTAssertEqual(SecretKey.tokenAccount(for: "gmail.private"), "gmail.private.tokens")
        XCTAssertEqual(
            SecretKey.tokenAccount(for: "gmail.dynamic-id"),
            "mail.gmail.dynamic-id.tokens"
        )
    }

    func testGmailHeaderParserKeepsFirstValueWhenHeadersRepeat() {
        let headers = GmailHeaderParser.values([
            ("Subject", "课程通知"),
            ("Received", "first relay"),
            ("received", "second relay"),
            ("From", "teacher@example.edu")
        ])

        XCTAssertEqual(headers["subject"], "课程通知")
        XCTAssertEqual(headers["received"], "first relay")
        XCTAssertEqual(headers["from"], "teacher@example.edu")
    }

    func testOpenAIQuotaErrorIsLocalized() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "error": [
                "message": "You exceeded your current quota.",
                "type": "insufficient_quota",
                "code": "insufficient_quota"
            ]
        ])

        XCTAssertEqual(
            OpenAIEmailSummarizer.serverErrorMessage(from: data),
            "OpenAI API 没有可用额度。请在 OpenAI Platform 添加付款方式或充值后重试。"
        )
    }

    func testOpenAIRetryDelayHonorsRetryAfter() {
        XCTAssertEqual(
            OpenAIEmailSummarizer.retryDelay(retryAfter: "5", attempt: 1, jitter: 0.25),
            5.25,
            accuracy: 0.001
        )
    }

    func testOpenAIResponseParserIgnoresReasoningItemsWithoutContent() throws {
        let response = #"{"status":"completed","output":[{"type":"reasoning"},{"type":"message","content":[{"type":"output_text","text":"{\"actions\":[]}"}]}]}"#

        let text = try OpenAIResponseParser.outputText(from: Data(response.utf8))

        XCTAssertEqual(text, #"{"actions":[]}"#)
    }

    func testOpenAIResponseParserUsesTopLevelOutputText() throws {
        let response = #"{"status":"completed","output_text":"{\"actions\":[]}","output":[]}"#

        let text = try OpenAIResponseParser.outputText(from: Data(response.utf8))

        XCTAssertEqual(text, #"{"actions":[]}"#)
    }

    func testOpenAIResponseParserRejectsIncompletePartialJSON() {
        let response = #"{"status":"incomplete","incomplete_details":{"reason":"max_output_tokens"},"output_text":"{\"actions\":[","output":[]}"#

        XCTAssertThrowsError(try OpenAIResponseParser.outputText(from: Data(response.utf8))) { error in
            XCTAssertTrue(error.localizedDescription.contains("max_output_tokens"))
        }
    }

    func testEmailContentCleanerRemovesQuotedHistory() {
        let source = "请在周五前提交表格。\n\nFrom: Older Sender\n旧邮件正文"
        XCTAssertEqual(EmailContentCleaner.clean(source), "请在周五前提交表格。")
    }

    func testOutlookAccountsAreMappedByAddressType() async {
        let suiteName = "OutlookAccountStoreTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = OutlookAccountStore(defaults: defaults)
        let mappings = await store.autoConfigure(from: [
            OutlookAccountInfo(name: "School", email: "student@example.edu"),
            OutlookAccountInfo(name: "Private Gmail", email: "person@gmail.com"),
            OutlookAccountInfo(name: "Private Outlook", email: "person@outlook.com")
        ])

        XCTAssertEqual(mappings["gmail.school"], "student@example.edu")
        XCTAssertEqual(mappings["gmail.private"], "person@gmail.com")
        XCTAssertEqual(mappings["outlook.private"], "person@outlook.com")
    }

    func testOutlookAppleScriptsCompile() {
        XCTAssertEqual(OutlookAutomation.scriptCompilationErrors(), [])
    }

    func testEmptyOutlookAccountResultDoesNotCrash() {
        let descriptor = NSAppleEventDescriptor.list()
        XCTAssertEqual(OutlookAutomation.parseAccountsForTesting(descriptor), [])
    }

    func testWebMailLinksUseSystemDefaultApplication() throws {
        let gmail = try XCTUnwrap(URL(string: "https://mail.google.com/mail/u/0/#inbox/thread-1"))
        let outlook = try XCTUnwrap(URL(string: "https://outlook.live.com/mail/0/inbox/id/message-1"))

        XCTAssertEqual(OriginalMessageRouter.route(for: gmail), .systemDefault)
        XCTAssertEqual(OriginalMessageRouter.route(for: outlook), .systemDefault)
    }

    func testLocalOutlookLinksUseOutlookAutomation() throws {
        let url = try XCTUnwrap(URL(string: "maildigest-outlook://message?account=user@example.com&id=123"))
        XCTAssertEqual(OriginalMessageRouter.route(for: url), .outlookAutomation)
    }

    func testDateOnlyDeadlineCreatesAllDayCalendarDraft() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let deadline = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026,
            month: 9,
            day: 10,
            hour: 12
        )))
        let item = DigestItem(
            accountID: "gmail.school",
            threadID: "thread-calendar-day",
            actionKey: "submit-homework",
            summary: "9月10日之前需要提交作业。",
            sender: "Teacher",
            receivedAt: deadline.addingTimeInterval(-86_400),
            deadline: deadline,
            deadlineHasTime: false,
            priority: .important
        )

        let draft = try CalendarEventDraftBuilder.make(from: item, calendar: calendar)

        XCTAssertTrue(draft.isAllDay)
        XCTAssertEqual(draft.startDate, calendar.startOfDay(for: deadline))
        XCTAssertEqual(
            draft.endDate,
            calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: deadline))
        )
    }

    func testTimedDeadlineCreatesOneHourCalendarDraft() throws {
        let deadline = Date(timeIntervalSince1970: 1_800_000_000)
        let item = DigestItem(
            accountID: "outlook.private",
            threadID: "thread-calendar-time",
            actionKey: "join-meeting",
            summary: "下午3点参加会议。",
            sender: "Organizer",
            receivedAt: deadline.addingTimeInterval(-3_600),
            deadline: deadline,
            deadlineHasTime: true,
            priority: .important
        )

        let draft = try CalendarEventDraftBuilder.make(from: item)

        XCTAssertFalse(draft.isAllDay)
        XCTAssertEqual(draft.startDate, deadline)
        XCTAssertEqual(draft.endDate, deadline.addingTimeInterval(3_600))
    }

    func testExplicitEndTimeKeepsProvidedCalendarSpan() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let end = start.addingTimeInterval(90 * 60)
        let item = DigestItem(
            accountID: "school-gmail",
            threadID: "thread-range",
            actionKey: "class-session",
            summary: "参加课程活动。",
            sender: "Instructor",
            receivedAt: start.addingTimeInterval(-3_600),
            deadline: start,
            deadlineEnd: end,
            deadlineHasTime: true,
            priority: .important
        )

        let draft = try CalendarEventDraftBuilder.make(from: item)

        XCTAssertEqual(draft.startDate, start)
        XCTAssertEqual(draft.endDate, end)
    }

    func testSummaryDeadlineParserRecoversChineseTimeRange() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        let reference = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 8, day: 30)))

        let parsed = try XCTUnwrap(SummaryDeadlineParser.parse(
            "9月2日下午2点到3点30分参加课程说明会。",
            referenceDate: reference,
            calendar: calendar
        ))

        XCTAssertEqual(calendar.component(.hour, from: parsed.date), 14)
        XCTAssertEqual(calendar.component(.hour, from: try XCTUnwrap(parsed.endDate)), 15)
        XCTAssertEqual(calendar.component(.minute, from: try XCTUnwrap(parsed.endDate)), 30)
    }

    func testCalendarConflictPromptNamesExistingEvent() {
        let prompt = CalendarConflictPrompt(
            itemID: UUID(),
            accountID: "gmail.school",
            conflictingTitles: ["课程讨论"]
        )

        XCTAssertEqual(prompt.message, "与“课程讨论”冲突，是否依然添加？")
    }

    func testThreadUpdateKeepsCalendarDuplicateProtection() {
        let eventID = "calendar-event-123"
        let old = DigestItem(
            accountID: "gmail.school",
            threadID: "thread-calendar-update",
            actionKey: "submit-project",
            summary: "提交项目初稿。",
            sender: "Teacher",
            receivedAt: .distantPast,
            deadline: .distantFuture,
            calendarEventIdentifier: eventID,
            priority: .important
        )
        let message = MailMessage(
            id: "message-calendar-update",
            threadID: old.threadID,
            accountID: old.accountID,
            subject: "截止时间更新",
            sender: old.sender,
            receivedAt: .now,
            bodyText: "The deadline has been updated.",
            originalURL: URL(string: "https://mail.google.com/"),
            attachments: []
        )
        let action = SummarizedAction(
            actionKey: old.actionKey,
            summary: "按照更新后的时间提交项目初稿。",
            deadline: .distantFuture,
            deadlineHasTime: false,
            priority: .important
        )

        let result = DigestMerger.merge(
            existing: [old],
            accountID: old.accountID,
            message: message,
            actions: [action]
        )

        XCTAssertEqual(result.items.first?.calendarEventIdentifier, eventID)
    }

    func testSummaryDeadlineParserRecoversChineseDateFromLegacyItem() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let reference = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026,
            month: 8,
            day: 29,
            hour: 10
        )))

        let parsed = try XCTUnwrap(SummaryDeadlineParser.parse(
            "2027年8月30日前使用你的100美元额度开始构建项目。",
            referenceDate: reference,
            calendar: calendar
        ))

        XCTAssertFalse(parsed.hasSpecificTime)
        XCTAssertEqual(calendar.component(.year, from: parsed.date), 2027)
        XCTAssertEqual(calendar.component(.month, from: parsed.date), 8)
        XCTAssertEqual(calendar.component(.day, from: parsed.date), 30)
    }

    func testSummaryDeadlineParserKeepsExplicitChineseTime() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let parsed = try XCTUnwrap(SummaryDeadlineParser.parse(
            "9月2日下午3:30参加课程会议。",
            referenceDate: Date(timeIntervalSince1970: 1_788_000_000),
            calendar: calendar
        ))

        XCTAssertTrue(parsed.hasSpecificTime)
        XCTAssertEqual(calendar.component(.hour, from: parsed.date), 15)
        XCTAssertEqual(calendar.component(.minute, from: parsed.date), 30)
    }
}
