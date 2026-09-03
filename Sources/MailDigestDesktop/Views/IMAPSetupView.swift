import SwiftUI

struct IMAPSetupView: View {
    @ObservedObject var state: AppState
    let account: MailAccount?
    @Environment(\.dismiss) private var dismiss
    @State private var emailAddress: String
    @State private var host: String
    @State private var port: Int
    @State private var username: String
    @State private var password = ""

    init(state: AppState, account: MailAccount? = nil) {
        self.state = state
        self.account = account
        let configuration = account?.imapConfiguration
            ?? IMAPConfiguration(emailAddress: "", host: "", username: "")
        _emailAddress = State(initialValue: configuration.emailAddress)
        _host = State(initialValue: configuration.host)
        _port = State(initialValue: configuration.port)
        _username = State(initialValue: configuration.username)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(account == nil
                ? L10n.text("添加其他邮箱", "Add Other Mail")
                : L10n.text("配置 IMAP 邮箱", "Configure IMAP Mailbox"))
                .font(.title2.weight(.semibold))

            Form {
                TextField(L10n.text("邮箱地址", "Email Address"), text: $emailAddress)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: emailAddress) { _, value in
                        let preset = IMAPPreset.configuration(for: value)
                        username = preset.username
                        host = preset.host
                        port = preset.port
                    }
                TextField(L10n.text("IMAP 服务器", "IMAP Server"), text: $host)
                    .textFieldStyle(.roundedBorder)
                TextField(L10n.text("端口", "Port"), value: $port, format: .number)
                    .textFieldStyle(.roundedBorder)
                TextField(L10n.text("用户名", "Username"), text: $username)
                    .textFieldStyle(.roundedBorder)
                SecureField(L10n.text("应用专用密码／授权码", "App Password / Authorization Code"), text: $password)
                    .textFieldStyle(.roundedBorder)
                Label(
                    L10n.text("始终使用 TLS 加密连接", "Always use a TLS-encrypted connection"),
                    systemImage: "lock.fill"
                )
            }
            .formStyle(.grouped)

            Text(L10n.text(
                "请使用邮箱服务商生成的应用专用密码或授权码。密码只保存在 macOS 钥匙串中。",
                "Use an app password or authorization code from your mail provider. It is stored only in macOS Keychain."
            ))
            .font(.caption)
            .foregroundStyle(.secondary)

            if let message = state.settingsMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                Button(L10n.text("取消", "Cancel")) { dismiss() }
                Button(L10n.text("测试并添加", "Test and Add")) {
                    let configuration = IMAPConfiguration(
                        emailAddress: emailAddress,
                        host: host,
                        port: port,
                        username: username,
                        useTLS: true
                    )
                    Task {
                        let succeeded: Bool
                        if let account {
                            succeeded = await state.configureIMAPAccount(
                                id: account.id,
                                configuration: configuration,
                                password: password
                            )
                        } else {
                            succeeded = await state.addIMAPAccount(
                                configuration: configuration,
                                password: password
                            )
                        }
                        if succeeded {
                            dismiss()
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(
                    state.isAddingIMAPAccount
                        || emailAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || password.isEmpty
                        || !(1...65_535).contains(port)
                )
            }
        }
        .padding(22)
        .frame(width: 470, height: 510)
    }
}
