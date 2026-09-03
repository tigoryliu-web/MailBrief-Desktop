import AppKit
import Foundation

final class OutlookAutomation: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.mailbrief.desktop.outlook-automation")
    private let maximumAttachmentBytes = 20 * 1_024 * 1_024

    func listAccounts() async throws -> [OutlookAccountInfo] {
        try await execute { [self] in
            let result = try runScript(Self.listAccountsScript)
            return Self.parseAccounts(result)
        }
    }

    func fetchMessages(
        accountID: String,
        accountAddress: String,
        since: Date
    ) async throws -> [MailMessage] {
        try await execute { [self] in
            let fileManager = FileManager.default
            let directory = fileManager.temporaryDirectory
                .appendingPathComponent("MailDigest-Outlook-\(UUID().uuidString)", isDirectory: true)
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? fileManager.removeItem(at: directory) }

            let lookback = max(0, Int(Date.now.timeIntervalSince(since).rounded(.up)))
            let script = Self.messagesScript(
                accountAddress: accountAddress,
                lookbackSeconds: lookback,
                attachmentDirectory: directory.path,
                maximumAttachmentBytes: maximumAttachmentBytes
            )
            let result = try runScript(script)
            return try Self.parseMessages(
                result,
                accountID: accountID,
                accountAddress: accountAddress,
                since: since
            )
        }
    }

    func openMessage(accountAddress: String, messageID: String) async throws {
        try await execute { [self] in
            _ = try runScript(Self.openMessageScript(
                accountAddress: accountAddress,
                messageID: messageID
            ))
        }
    }

    static func scriptCompilationErrors() -> [String] {
        let scripts = [
            listAccountsScript,
            messagesScript(
                accountAddress: "example@gmail.com",
                lookbackSeconds: 86_400,
                attachmentDirectory: "/tmp/MailDigest-Validation",
                maximumAttachmentBytes: 20 * 1_024 * 1_024
            ),
            openMessageScript(accountAddress: "example@gmail.com", messageID: "1")
        ]
        return scripts.compactMap { source in
            guard let script = NSAppleScript(source: source) else {
                return L10n.text("无法创建 Outlook 脚本", "Could not create the Outlook script")
            }
            var errorInfo: NSDictionary?
            if script.compileAndReturnError(&errorInfo) { return nil }
            let range = (errorInfo?[NSAppleScript.errorRange] as? NSValue)?.rangeValue ?? .init()
            let start = source.index(source.startIndex, offsetBy: min(range.location, source.count))
            let end = source.index(start, offsetBy: min(max(range.length, 40), source.distance(from: start, to: source.endIndex)))
            return L10n.text(
                "\(errorInfo?.description ?? "未知编译错误")\n附近：\(source[start..<end])",
                "\(errorInfo?.description ?? "Unknown compilation error")\nNear: \(source[start..<end])"
            )
        }
    }

    static func parseAccountsForTesting(
        _ descriptor: NSAppleEventDescriptor
    ) -> [OutlookAccountInfo] {
        parseAccounts(descriptor)
    }

    private func execute<T: Sendable>(_ operation: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do { continuation.resume(returning: try operation()) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }

    private func runScript(_ source: String) throws -> NSAppleEventDescriptor {
        guard NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.microsoft.Outlook") != nil else {
            throw MailServiceError.outlookNotInstalled
        }
        guard let script = NSAppleScript(source: source) else {
            throw MailServiceError.invalidResponse
        }
        var errorInfo: NSDictionary?
        let result = script.executeAndReturnError(&errorInfo)
        if let errorInfo {
            let number = errorInfo[NSAppleScript.errorNumber] as? Int
            if number == -1743 {
                throw MailServiceError.outlookAutomationDenied
            }
            if number == -1728 {
                throw MailServiceError.outlookAccountMissing
            }
            let message = (errorInfo[NSAppleScript.errorMessage] as? String)
                ?? L10n.text("Outlook 返回了未知错误。", "Outlook returned an unknown error.")
            throw MailServiceError.server(message)
        }
        return result
    }

    private static func parseAccounts(_ descriptor: NSAppleEventDescriptor) -> [OutlookAccountInfo] {
        let itemCount = descriptor.numberOfItems
        guard itemCount > 0 else { return [] }
        return (1...itemCount).compactMap { index in
            guard let row = descriptor.atIndex(index),
                  let name = row.atIndex(1)?.stringValue,
                  let email = row.atIndex(2)?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !email.isEmpty
            else { return nil }
            return OutlookAccountInfo(name: name, email: email.lowercased())
        }
    }

    private static func parseMessages(
        _ descriptor: NSAppleEventDescriptor,
        accountID: String,
        accountAddress: String,
        since: Date
    ) throws -> [MailMessage] {
        let itemCount = descriptor.numberOfItems
        guard itemCount > 0 else { return [] }
        return (1...itemCount).compactMap { index in
            guard let row = descriptor.atIndex(index),
                  let messageID = row.atIndex(1)?.stringValue,
                  let subject = row.atIndex(3)?.stringValue,
                  let sender = row.atIndex(4)?.stringValue,
                  let receivedAt = row.atIndex(5)?.dateValue as Date?,
                  let body = row.atIndex(6)?.stringValue
            else { return nil }
            guard receivedAt >= since else { return nil }

            let threadValue = row.atIndex(2)?.stringValue
            let attachmentRows = row.atIndex(7)
            var attachments: [MailAttachment] = []
            if let attachmentRows, attachmentRows.numberOfItems > 0 {
                for attachmentIndex in 1...attachmentRows.numberOfItems {
                    guard let attachment = attachmentRows.atIndex(attachmentIndex),
                          let filename = attachment.atIndex(1)?.stringValue,
                          let mimeType = attachment.atIndex(2)?.stringValue,
                          let path = attachment.atIndex(3)?.stringValue,
                          !path.isEmpty,
                          let data = try? Data(contentsOf: URL(fileURLWithPath: path))
                    else { continue }
                    attachments.append(MailAttachment(filename: filename, mimeType: mimeType, data: data))
                }
            }

            var components = URLComponents()
            components.scheme = "maildigest-outlook"
            components.host = "message"
            components.queryItems = [
                URLQueryItem(name: "account", value: accountAddress),
                URLQueryItem(name: "id", value: messageID)
            ]
            return MailMessage(
                id: messageID,
                threadID: (threadValue?.isEmpty == false ? threadValue! : messageID),
                accountID: accountID,
                subject: subject,
                sender: sender,
                receivedAt: receivedAt,
                bodyText: EmailContentCleaner.clean(body),
                originalURL: components.url,
                attachments: attachments
            )
        }
    }

    private static let listAccountsScript = commonHandlers + """

    tell application "/Applications/Microsoft Outlook.app"
        set resultRows to {}
        set seenAddresses to {}
        repeat with acct in my allMailAccounts()
            set accountAddress to my safeText(email address of acct)
            if accountAddress is not "" then
                set end of resultRows to {my safeText(name of acct), accountAddress}
                set end of seenAddresses to accountAddress
            end if
        end repeat
        if (count of resultRows) is 0 then
            set totalMessages to count of incoming messages
            set maximumMessages to 1000
            if totalMessages is less than maximumMessages then set maximumMessages to totalMessages
            if maximumMessages is greater than 0 then
                repeat with messageCounter from 1 to maximumMessages
                    set msg to incoming message messageCounter
                    try
                        set msgAccount to account of msg
                        set accountAddress to my safeText(email address of msgAccount)
                        if accountAddress is not "" and seenAddresses does not contain accountAddress then
                            set end of resultRows to {my safeText(name of msgAccount), accountAddress}
                            set end of seenAddresses to accountAddress
                        end if
                    end try
                end repeat
            end if
        end if
        return resultRows
    end tell
    """

    private static func messagesScript(
        accountAddress: String,
        lookbackSeconds: Int,
        attachmentDirectory: String,
        maximumAttachmentBytes: Int
    ) -> String {
        commonHandlers + """

        set sinceDate to run script "(current date) - \(lookbackSeconds)"
        tell application "/Applications/Microsoft Outlook.app"
            set targetAddress to "\(escape(accountAddress.lowercased()))"
            set targetAccount to my findAccount(targetAddress)
            if targetAccount is missing value then
                set candidateMessages to every incoming message whose time received is greater than sinceDate
            else
                set inboxFolder to inbox of targetAccount
                set candidateMessages to every message of inboxFolder whose time received is greater than sinceDate
            end if
            set totalMessages to count of candidateMessages
            set maximumMessages to 500
            if totalMessages is less than maximumMessages then set maximumMessages to totalMessages
            set resultRows to {}
            repeat with messageCounter from 1 to maximumMessages
                set msg to item messageCounter of candidateMessages
                set shouldInclude to true
                if targetAccount is missing value then
                    set shouldInclude to false
                    try
                        set messageAccountAddress to my safeText(email address of account of msg)
                        ignoring case
                            if messageAccountAddress is targetAddress then set shouldInclude to true
                        end ignoring
                    end try
                end if
                if shouldInclude then
                set messageID to my safeText(id of msg)
                set threadValue to ""
                try
                    set threadValue to my safeText(local thread guid of msg)
                end try
                if threadValue is "" then
                    try
                        set threadValue to my safeText(conversation id of msg)
                    end try
                end if
                set senderValue to ""
                try
                    set senderValue to my safeText(address of sender of msg)
                on error
                    set senderValue to my safeText(sender of msg)
                end try
                set attachmentRows to {}
                set attachmentCounter to 0
                repeat with att in attachments of msg
                    set attachmentCounter to attachmentCounter + 1
                    set attachmentName to my safeText(name of att)
                    set attachmentType to my safeText(content type of att)
                    set attachmentSize to 0
                    try
                        set attachmentSize to file size of att
                    end try
                    set savedPath to ""
                    if attachmentSize is greater than 0 and attachmentSize is less than or equal to \(maximumAttachmentBytes) then
                        set savedPath to "\(escape(attachmentDirectory))/attachment-" & messageCounter & "-" & attachmentCounter
                        try
                            save att in (POSIX file savedPath)
                        on error
                            set savedPath to ""
                        end try
                    end if
                    set end of attachmentRows to {attachmentName, attachmentType, savedPath}
                end repeat
                set end of resultRows to {messageID, threadValue, my safeText(subject of msg), senderValue, time received of msg, my safeText(plain text content of msg), attachmentRows}
                end if
            end repeat
            return resultRows
        end tell
        """
    }

    private static func openMessageScript(accountAddress: String, messageID: String) -> String {
        commonHandlers + """

        tell application "/Applications/Microsoft Outlook.app"
            set targetAccount to my findAccount("\(escape(accountAddress.lowercased()))")
            set targetID to \(Int(messageID) ?? -1)
            if targetAccount is missing value then
                set targetMessage to first incoming message whose id is targetID
            else
                set targetMessage to first message of (inbox of targetAccount) whose id is targetID
            end if
            open targetMessage
            activate
        end tell
        """
    }

    private static let commonHandlers = """
    on safeText(valueToRead)
        try
            return valueToRead as text
        on error
            return ""
        end try
    end safeText

    on allMailAccounts()
        tell application "/Applications/Microsoft Outlook.app"
            set accountRows to {}
            try
                set accountRows to accountRows & (every exchange account)
            end try
            try
                set accountRows to accountRows & (every imap account)
            end try
            try
                set accountRows to accountRows & (every pop account)
            end try
            return accountRows
        end tell
    end allMailAccounts

    on findAccount(targetAddress)
        tell application "/Applications/Microsoft Outlook.app"
            repeat with acct in my allMailAccounts()
                ignoring case
                    if my safeText(email address of acct) is targetAddress then return acct
                end ignoring
            end repeat
        end tell
        return missing value
    end findAccount
    """

    private static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}

enum EmailContentCleaner {
    private static let separators = [
        "-----Original Message-----",
        "________________________________",
        "From:",
        "发件人："
    ]

    static func clean(_ source: String) -> String {
        var text = source.replacingOccurrences(of: "\r\n", with: "\n")
        for separator in separators {
            if let range = text.range(of: "\n\(separator)", options: .caseInsensitive) {
                text = String(text[..<range.lowerBound])
            }
        }
        if let range = text.range(
            of: "\\nOn .{1,300} wrote:\\s*\\n",
            options: [.regularExpression, .caseInsensitive]
        ) {
            text = String(text[..<range.lowerBound])
        }
        text = text.replacingOccurrences(
            of: "[ \\t]+\\n",
            with: "\n",
            options: .regularExpression
        )
        text = text.replacingOccurrences(
            of: "\\n{3,}",
            with: "\n\n",
            options: .regularExpression
        )
        return String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(32_000))
    }
}
