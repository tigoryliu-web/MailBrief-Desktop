import Foundation
import UserNotifications

struct DigestNotificationService: Sendable {
    func requestAuthorization() async {
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
    }

    func sendRefreshSummary(newCount: Int, urgentCount: Int) async {
        guard newCount > 0 else { return }

        let content = UNMutableNotificationContent()
        content.title = L10n.text("邮件摘要已更新", "Mail Digest Updated")
        if urgentCount > 0 {
            content.body = L10n.text(
                "发现 \(newCount) 条新信息，其中 \(urgentCount) 条紧急。",
                "Found \(newCount) new items, including \(urgentCount) urgent."
            )
        } else {
            content.body = L10n.text("发现 \(newCount) 条新信息。", "Found \(newCount) new items.")
        }
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "mail-refresh-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        try? await UNUserNotificationCenter.current().add(request)
    }

    func sendScheduledUrgentSummary(count: Int) async {
        guard count > 0 else { return }
        let content = UNMutableNotificationContent()
        content.title = L10n.text("发现紧急邮件", "Urgent Mail Found")
        content.body = count == 1
            ? L10n.text("定时刷新发现了 1 条紧急事项。", "Scheduled refresh found 1 urgent item.")
            : L10n.text("定时刷新发现了 \(count) 条紧急事项。", "Scheduled refresh found \(count) urgent items.")
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: "scheduled-urgent-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        try? await UNUserNotificationCenter.current().add(request)
    }

    func sendUrgencyEscalation(count: Int) async {
        guard count > 0 else { return }

        let content = UNMutableNotificationContent()
        content.title = L10n.text("待办已升级为紧急", "Item Escalated to Urgent")
        content.body = count == 1
            ? L10n.text("有 1 条未完成事项临近截止日期。", "1 incomplete item is approaching its deadline.")
            : L10n.text("有 \(count) 条未完成事项临近截止日期。", "\(count) incomplete items are approaching their deadlines.")
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "urgent-escalation-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        try? await UNUserNotificationCenter.current().add(request)
    }

    func sendTestNotification() async {
        let content = UNMutableNotificationContent()
        content.title = L10n.text("邮件摘要通知测试", "Mail Digest Notification Test")
        content.body = L10n.text(
            "如果左侧显示蓝色邮件摘要图标，通知图标已经配置成功。",
            "If the blue Mail Digest icon appears, notification icons are configured correctly."
        )
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "notification-icon-test-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        try? await UNUserNotificationCenter.current().add(request)
    }
}
