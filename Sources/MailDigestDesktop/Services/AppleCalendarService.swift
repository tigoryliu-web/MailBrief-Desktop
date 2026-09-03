import EventKit
import Foundation

enum AppleCalendarError: LocalizedError {
    case missingDeadline
    case permissionDenied
    case noDefaultCalendar
    case saveFailed

    var errorDescription: String? {
        switch self {
        case .missingDeadline:
            L10n.text(
                "这条摘要没有明确日期，无法添加到日历。",
                "This digest has no clear date and cannot be added to Calendar."
            )
        case .permissionDenied:
            L10n.text(
                "没有日历访问权限。请在“系统设置 → 隐私与安全性 → 日历”中允许“邮件摘要”。",
                "Calendar access is unavailable. In System Settings > Privacy & Security > Calendars, allow Mail Digest."
            )
        case .noDefaultCalendar:
            L10n.text(
                "没有找到可写入的默认日历，请先在 Apple 日历中创建或启用一个日历。",
                "No writable default calendar was found. Create or enable one in Apple Calendar first."
            )
        case .saveFailed:
            L10n.text(
                "日历事件已创建，但系统没有返回可用于防重复的事件标识。",
                "The calendar event was created, but macOS did not return an identifier for duplicate protection."
            )
        }
    }
}

struct CalendarEventDraft: Equatable, Sendable {
    var title: String
    var startDate: Date
    var endDate: Date
    var isAllDay: Bool
    var notes: String
    var url: URL?
}

struct CalendarConflict: Equatable, Sendable {
    var title: String
    var startDate: Date
    var endDate: Date
    var isAllDay: Bool
}

enum CalendarEventDraftBuilder {
    static func make(
        from item: DigestItem,
        calendar: Calendar = .current
    ) throws -> CalendarEventDraft {
        guard let deadline = item.deadline else {
            throw AppleCalendarError.missingDeadline
        }

        let hasSpecificTime = item.deadlineHasTime == true
        let startDate: Date
        let endDate: Date
        if hasSpecificTime {
            startDate = deadline
            endDate = item.deadlineEnd.flatMap { $0 > deadline ? $0 : nil }
                ?? deadline.addingTimeInterval(60 * 60)
        } else {
            startDate = calendar.startOfDay(for: deadline)
            guard let nextDay = calendar.date(byAdding: .day, value: 1, to: startDate) else {
                throw AppleCalendarError.saveFailed
            }
            endDate = nextDay
        }

        var notes = L10n.text(
            "来自邮件摘要\n发件人：\(item.sender)\n接收时间：\(L10n.dateTime(item.receivedAt))",
            "From Mail Digest\nSender: \(item.sender)\nReceived: \(L10n.dateTime(item.receivedAt))"
        )
        if let originalURL = item.originalURL {
            notes += L10n.text("\n原邮件：\(originalURL)", "\nOriginal email: \(originalURL)")
        }

        return CalendarEventDraft(
            title: item.summary,
            startDate: startDate,
            endDate: endDate,
            isAllDay: !hasSpecificTime,
            notes: notes,
            url: item.originalURL.flatMap(URL.init(string:))
        )
    }
}

@MainActor
final class AppleCalendarService {
    private let eventStore: EKEventStore

    init(eventStore: EKEventStore = EKEventStore()) {
        self.eventStore = eventStore
    }

    func conflicts(for item: DigestItem) async throws -> [CalendarConflict] {
        let draft = try CalendarEventDraftBuilder.make(from: item)
        try await ensureAccess()

        let predicate = eventStore.predicateForEvents(
            withStart: draft.startDate,
            end: draft.endDate,
            calendars: nil
        )
        return eventStore.events(matching: predicate)
            .filter { $0.status != .canceled && $0.availability != .free }
            .map {
                CalendarConflict(
                    title: $0.title?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                        ? $0.title!
                        : L10n.text("未命名日程", "Untitled Event"),
                    startDate: $0.startDate,
                    endDate: $0.endDate,
                    isAllDay: $0.isAllDay
                )
            }
            .sorted { $0.startDate < $1.startDate }
    }

    func add(_ item: DigestItem) async throws -> String {
        let draft = try CalendarEventDraftBuilder.make(from: item)
        try await ensureAccess()
        guard let calendar = eventStore.defaultCalendarForNewEvents else {
            throw AppleCalendarError.noDefaultCalendar
        }

        let event = EKEvent(eventStore: eventStore)
        event.calendar = calendar
        event.title = draft.title
        event.startDate = draft.startDate
        event.endDate = draft.endDate
        event.isAllDay = draft.isAllDay
        event.notes = draft.notes
        event.url = draft.url

        try eventStore.save(event, span: .thisEvent, commit: true)
        guard let identifier = event.eventIdentifier, !identifier.isEmpty else {
            throw AppleCalendarError.saveFailed
        }
        return identifier
    }

    private func ensureAccess() async throws {
        let granted = try await eventStore.requestFullAccessToEvents()
        guard granted else { throw AppleCalendarError.permissionDenied }
    }
}
