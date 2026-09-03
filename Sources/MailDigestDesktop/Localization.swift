import Foundation

enum L10n {
    private static let languageKey = "app.language"

    static var language: AppLanguage {
        get {
            guard let raw = UserDefaults.standard.string(forKey: languageKey),
                  let value = AppLanguage(rawValue: raw)
            else { return .simplifiedChinese }
            return value
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: languageKey)
        }
    }

    static func text(_ chinese: String, _ english: String) -> String {
        language == .english ? english : chinese
    }

    static func accountDefaultTitle(provider: MailProvider) -> String {
        switch provider {
        case .gmail: "Gmail"
        case .outlook: "Outlook"
        case .imap: text("其他邮箱", "Other Mail")
        }
    }

    static func legacyAccountTitle(id: String, language: AppLanguage) -> String? {
        switch (id, language) {
        case ("gmail.private", .simplifiedChinese): "私人 Gmail"
        case ("gmail.private", .english): "Personal Gmail"
        case ("gmail.school", .simplifiedChinese): "学校 Gmail"
        case ("gmail.school", .english): "School Gmail"
        case ("outlook.private", .simplifiedChinese): "私人 Outlook"
        case ("outlook.private", .english): "Personal Outlook"
        default: nil
        }
    }

    static func legacyAccountSubtitle(id: String, language: AppLanguage) -> String? {
        switch (id, language) {
        case ("gmail.private", .simplifiedChinese), ("outlook.private", .simplifiedChinese): "私人账号"
        case ("gmail.private", .english), ("outlook.private", .english): "Personal Account"
        case ("gmail.school", .simplifiedChinese): "学校账号"
        case ("gmail.school", .english): "School Account"
        default: nil
        }
    }

    static func dateTime(_ date: Date, includeDate: Bool = true) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: language.rawValue)
        formatter.dateStyle = includeDate ? .medium : .none
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    static func time(_ scheduledTime: ScheduledTime) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: language.rawValue)
        formatter.dateFormat = language == .english ? "h:mm a" : "HH:mm"
        return formatter.string(from: scheduledTime.dateForPicker)
    }
}
