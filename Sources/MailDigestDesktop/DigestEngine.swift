import Foundation

enum PriorityEngine {
    static func priority(
        deadline: Date?,
        suggested: DigestPriority,
        now: Date = .now,
        calendar: Calendar = .current
    ) -> DigestPriority {
        guard let deadline else { return suggested }

        if deadline <= now {
            return .urgent
        }

        let hours = calendar.dateComponents([.hour], from: now, to: deadline).hour ?? 0
        if hours <= 24 {
            return .urgent
        }
        if hours <= 72 {
            return suggested == .urgent ? .urgent : .important
        }
        return suggested
    }
}

struct DigestMergeResult: Sendable {
    var items: [DigestItem]
    var insertedCount: Int
}

enum DigestMerger {
    static func merge(
        existing: [DigestItem],
        accountID: String,
        message: MailMessage,
        actions: [SummarizedAction],
        now: Date = .now
    ) -> DigestMergeResult {
        let untouched = existing.filter { $0.threadID != message.threadID }
        let replacements = actions.map { action in
            let previous = existing.first {
                $0.threadID == message.threadID && $0.actionKey == action.actionKey
            }
            let computed = PriorityEngine.priority(
                deadline: action.deadline,
                suggested: action.priority,
                now: now
            )
            return DigestItem(
                accountID: accountID,
                threadID: message.threadID,
                actionKey: action.actionKey,
                summary: action.summary,
                sender: message.sender,
                receivedAt: message.receivedAt,
                deadline: action.deadline,
                deadlineEnd: action.deadlineEnd,
                deadlineHasTime: action.deadlineHasTime,
                originalURL: message.originalURL?.absoluteString,
                calendarEventIdentifier: previous?.calendarEventIdentifier,
                priority: computed,
                mailType: action.mailType,
                suggestedPriority: action.priority,
                isCompleted: false,
                isNew: true,
                urgentNotificationSent: false,
                updatedAt: now
            )
        }

        return DigestMergeResult(
            items: sorted(untouched + replacements),
            insertedCount: replacements.count
        )
    }

    static func recalculate(
        _ items: [DigestItem],
        now: Date = .now
    ) -> (items: [DigestItem], newlyUrgent: Int) {
        var newlyUrgent = 0
        let updated = items.map { item -> DigestItem in
            guard !item.isCompleted else { return item }
            var copy = item
            let oldPriority = copy.priority
            copy.priority = PriorityEngine.priority(
                deadline: copy.deadline,
                suggested: copy.suggestedPriority,
                now: now
            )
            if oldPriority != .urgent, copy.priority == .urgent, !copy.urgentNotificationSent {
                newlyUrgent += 1
                copy.urgentNotificationSent = true
            }
            return copy
        }
        return (sorted(updated), newlyUrgent)
    }

    static func sorted(_ items: [DigestItem]) -> [DigestItem] {
        items.sorted {
            if $0.isCompleted != $1.isCompleted {
                return !$0.isCompleted
            }
            if $0.priority.sortRank != $1.priority.sortRank {
                return $0.priority.sortRank < $1.priority.sortRank
            }
            if $0.deadline != $1.deadline {
                switch ($0.deadline, $1.deadline) {
                case let (lhs?, rhs?): return lhs < rhs
                case (_?, nil): return true
                case (nil, _?): return false
                case (nil, nil): break
                }
            }
            return $0.receivedAt > $1.receivedAt
        }
    }
}

struct ParsedSummaryDeadline: Equatable, Sendable {
    var date: Date
    var endDate: Date?
    var hasSpecificTime: Bool
}

enum SummaryDeadlineParser {
    static func parse(
        _ summary: String,
        referenceDate: Date = .now,
        calendar: Calendar = .current
    ) -> ParsedSummaryDeadline? {
        parseChineseDate(summary, referenceDate: referenceDate, calendar: calendar)
            ?? parseNumericDate(summary, calendar: calendar)
    }

    private static func parseChineseDate(
        _ summary: String,
        referenceDate: Date,
        calendar: Calendar
    ) -> ParsedSummaryDeadline? {
        let pattern = #"(?:(\d{4})\s*年\s*)?(\d{1,2})\s*月\s*(\d{1,2})\s*日(?:\s*(上午|下午|晚上)?\s*(\d{1,2})(?:[:：](\d{1,2})|点(?:\s*(\d{1,2})分?)?))?"#
        guard let match = firstMatch(pattern: pattern, in: summary) else { return nil }

        let explicitYear = integer(match, group: 1, in: summary)
        let referenceYear = calendar.component(.year, from: referenceDate)
        guard let month = integer(match, group: 2, in: summary),
              let day = integer(match, group: 3, in: summary)
        else { return nil }

        let period = string(match, group: 4, in: summary)
        var hour = integer(match, group: 5, in: summary)
        let minute = integer(match, group: 6, in: summary)
            ?? integer(match, group: 7, in: summary)
            ?? 0
        let hasSpecificTime = hour != nil
        if let period, var adjustedHour = hour {
            if (period == "下午" || period == "晚上"), adjustedHour < 12 {
                adjustedHour += 12
            } else if period == "上午", adjustedHour == 12 {
                adjustedHour = 0
            }
            hour = adjustedHour
        }

        func candidate(year: Int) -> Date? {
            calendar.date(from: DateComponents(
                year: year,
                month: month,
                day: day,
                hour: hour ?? 12,
                minute: minute
            ))
        }

        var year = explicitYear ?? referenceYear
        guard var date = candidate(year: year) else { return nil }
        if explicitYear == nil,
           calendar.startOfDay(for: date) < calendar.startOfDay(for: referenceDate) {
            year += 1
            guard let nextYearDate = candidate(year: year) else { return nil }
            date = nextYearDate
        }
        let endDate = hasSpecificTime
            ? parseEndTime(
                in: summary,
                after: match.range.location + match.range.length,
                startDate: date,
                inheritedPeriod: period,
                calendar: calendar
            )
            : nil
        return ParsedSummaryDeadline(date: date, endDate: endDate, hasSpecificTime: hasSpecificTime)
    }

    private static func parseNumericDate(
        _ summary: String,
        calendar: Calendar
    ) -> ParsedSummaryDeadline? {
        let pattern = #"(\d{4})[-/](\d{1,2})[-/](\d{1,2})(?:[ T](\d{1,2}):([0-5]\d))?"#
        guard let match = firstMatch(pattern: pattern, in: summary),
              let year = integer(match, group: 1, in: summary),
              let month = integer(match, group: 2, in: summary),
              let day = integer(match, group: 3, in: summary)
        else { return nil }

        let hour = integer(match, group: 4, in: summary)
        let minute = integer(match, group: 5, in: summary) ?? 0
        guard let date = calendar.date(from: DateComponents(
            year: year,
            month: month,
            day: day,
            hour: hour ?? 12,
            minute: minute
        )) else { return nil }
        let endDate = hour == nil
            ? nil
            : parseEndTime(
                in: summary,
                after: match.range.location + match.range.length,
                startDate: date,
                inheritedPeriod: nil,
                calendar: calendar
            )
        return ParsedSummaryDeadline(date: date, endDate: endDate, hasSpecificTime: hour != nil)
    }

    private static func parseEndTime(
        in summary: String,
        after utf16Offset: Int,
        startDate: Date,
        inheritedPeriod: String?,
        calendar: Calendar
    ) -> Date? {
        let utf16 = summary.utf16
        guard let startIndex = utf16.index(utf16.startIndex, offsetBy: utf16Offset, limitedBy: utf16.endIndex),
              let scalarIndex = String.Index(startIndex, within: summary)
        else { return nil }

        let suffix = String(summary[scalarIndex...])
        let pattern = #"^\s*(?:到|至|—|–|-|~|～)\s*(上午|下午|晚上)?\s*(\d{1,2})(?:[:：](\d{1,2})|点(?:\s*(\d{1,2})分?)?)"#
        guard let match = firstMatch(pattern: pattern, in: suffix),
              var hour = integer(match, group: 2, in: suffix)
        else { return nil }

        let explicitPeriod = string(match, group: 1, in: suffix)
        let period = explicitPeriod ?? inheritedPeriod
        let minute = integer(match, group: 3, in: suffix)
            ?? integer(match, group: 4, in: suffix)
            ?? 0
        if let period {
            if (period == "下午" || period == "晚上"), hour < 12 {
                hour += 12
            } else if period == "上午", hour == 12 {
                hour = 0
            }
        }

        let startComponents = calendar.dateComponents([.year, .month, .day], from: startDate)
        var endComponents = startComponents
        endComponents.hour = hour
        endComponents.minute = minute
        guard var endDate = calendar.date(from: endComponents) else { return nil }

        if endDate <= startDate, explicitPeriod == nil, inheritedPeriod == nil, hour < 12 {
            endComponents.hour = hour + 12
            if let adjusted = calendar.date(from: endComponents), adjusted > startDate {
                endDate = adjusted
            }
        }
        if endDate <= startDate {
            endDate = calendar.date(byAdding: .day, value: 1, to: endDate) ?? endDate
        }
        return endDate > startDate ? endDate : nil
    }

    private static func firstMatch(pattern: String, in value: String) -> NSTextCheckingResult? {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return nil }
        return expression.firstMatch(
            in: value,
            range: NSRange(value.startIndex..<value.endIndex, in: value)
        )
    }

    private static func string(
        _ match: NSTextCheckingResult,
        group: Int,
        in value: String
    ) -> String? {
        let range = match.range(at: group)
        guard range.location != NSNotFound, let swiftRange = Range(range, in: value) else {
            return nil
        }
        return String(value[swiftRange])
    }

    private static func integer(
        _ match: NSTextCheckingResult,
        group: Int,
        in value: String
    ) -> Int? {
        string(match, group: group, in: value).flatMap(Int.init)
    }
}
