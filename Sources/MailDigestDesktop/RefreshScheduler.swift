import Foundation

enum RefreshSchedule {
    static func normalized(_ times: [ScheduledTime]) -> [ScheduledTime] {
        Array(Set(times)).sorted().prefix(5).map { $0 }
    }

    static func scheduledTime(
        at date: Date,
        enabled: Bool,
        times: [ScheduledTime],
        calendar: Calendar = .current
    ) -> ScheduledTime? {
        guard enabled else { return nil }
        let hour = calendar.component(.hour, from: date)
        let minute = calendar.component(.minute, from: date)
        return normalized(times).first { $0.hour == hour && $0.minute == minute }
    }

    static func allAccountsWereRecentlyRefreshed(
        _ sections: [AccountSection],
        at date: Date,
        interval: TimeInterval = 15 * 60
    ) -> Bool {
        let connected = sections.filter(\.account.isConfigured)
        guard !connected.isEmpty else { return true }
        return connected.allSatisfy {
            guard let last = $0.lastSuccessfulRefresh else { return false }
            return date.timeIntervalSince(last) >= 0 && date.timeIntervalSince(last) < interval
        }
    }
}

@MainActor
final class RefreshScheduler {
    private weak var state: AppState?
    private var timer: Timer?
    private var lastObservedMinute: String?

    init(state: AppState) {
        self.state = state
    }

    func start() {
        lastObservedMinute = minuteKey(for: .now)
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        if let timer { RunLoop.main.add(timer, forMode: .common) }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func tick(now: Date = .now) {
        let key = minuteKey(for: now)
        guard key != lastObservedMinute else { return }
        lastObservedMinute = key
        guard let state,
              RefreshSchedule.scheduledTime(
                at: now,
                enabled: state.settings.scheduledRefreshEnabled,
                times: state.settings.scheduledTimes
              ) != nil
        else { return }
        Task { await state.refresh(trigger: .scheduled) }
    }

    private func minuteKey(for date: Date) -> String {
        let components = Calendar.current.dateComponents([.era, .year, .month, .day, .hour, .minute], from: date)
        return [components.era, components.year, components.month, components.day, components.hour, components.minute]
            .map { String($0 ?? 0) }
            .joined(separator: "-")
    }
}
