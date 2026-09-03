import SwiftUI

struct SettingsView: View {
    @ObservedObject var state: AppState
    @State private var apiKey = ""
    @State private var googleClientID = ""
    @State private var googleClientSecret = ""
    @State private var microsoftClientID = ""
    @State private var newRefreshTime = Calendar.current.date(from: DateComponents(hour: 8)) ?? .now
    @State private var accountPendingRemoval: MailAccount?
    @State private var imapAccountToConfigure: MailAccount?

    var body: some View {
        TabView {
            accountsTab
                .tabItem { Label(L10n.text("邮箱", "Mailboxes"), systemImage: "envelope") }
            aiTab
                .tabItem { Label(L10n.text("AI 摘要", "AI Digest"), systemImage: "sparkles") }
            generalTab
                .tabItem { Label(L10n.text("通用", "General"), systemImage: "gearshape") }
        }
        .frame(width: 630, height: 650)
        .padding(16)
        .alert(item: $accountPendingRemoval) { account in
            Alert(
                title: Text(L10n.text("移除邮箱？", "Remove Mailbox?")),
                message: Text(L10n.text(
                    "只会删除本机中的账户配置、授权令牌和邮件摘要，不会删除邮箱中的任何邮件。",
                    "This removes local settings, authorization tokens, and digests only. It does not delete any email from the mailbox."
                )),
                primaryButton: .destructive(Text(L10n.text("移除", "Remove"))) {
                    state.removeAccount(account)
                },
                secondaryButton: .cancel(Text(L10n.text("取消", "Cancel")))
            )
        }
        .sheet(item: $imapAccountToConfigure) { account in
            IMAPSetupView(state: state, account: account)
        }
    }

    private var accountsTab: some View {
        List {
            Section(L10n.text("Google 桌面应用", "Google Desktop App")) {
                TextField("Google Client ID", text: $googleClientID)
                    .textFieldStyle(.roundedBorder)
                SecureField("Google Client Secret", text: $googleClientSecret)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Button(L10n.text("保存 Google 配置", "Save Google Settings")) {
                        state.saveGoogleOAuthClient(clientID: googleClientID, clientSecret: googleClientSecret)
                        googleClientID = ""
                        googleClientSecret = ""
                    }
                    .disabled(
                        googleClientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || googleClientSecret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    )
                    Spacer()
                    configurationStatus(state.hasGoogleOAuthClient)
                }
            }

            Section(L10n.text("Microsoft 个人账号应用", "Microsoft Personal Account App")) {
                TextField("Microsoft Application (client) ID", text: $microsoftClientID)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Button(L10n.text("保存 Microsoft 配置", "Save Microsoft Settings")) {
                        state.saveMicrosoftClientID(microsoftClientID)
                        microsoftClientID = ""
                    }
                    .disabled(microsoftClientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Spacer()
                    configurationStatus(state.hasMicrosoftClientID)
                }
            }

            Section(L10n.text("只读邮箱账号（最多5个）", "Read-only Mailboxes (Up to 5)")) {
                ForEach(Array(state.sections.enumerated()), id: \.element.id) { index, section in
                    accountRow(section, index: index)
                }
                .onMove(perform: state.moveAccounts)
            }

            Section {
                Text(L10n.text(
                    "Gmail 和 Microsoft 使用只读 OAuth；其他邮箱使用加密 IMAP。应用不会标记已读、删除、归档或发送邮件。令牌和密码仅保存在 macOS 钥匙串。",
                    "Gmail and Microsoft use read-only OAuth; other providers use encrypted IMAP. The app never marks, deletes, archives, or sends email. Tokens and passwords stay in macOS Keychain."
                ))
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            if let message = state.settingsMessage {
                Section { Text(message).font(.caption).foregroundStyle(.secondary) }
            }
        }
        .listStyle(.inset)
    }

    private func accountRow(_ section: AccountSection, index: Int) -> some View {
        HStack(spacing: 10) {
            Image(systemName: providerIcon(section.account.provider))
                .foregroundStyle(providerColor(section.account.provider))
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 3) {
                TextField(L10n.text("邮箱名称", "Mailbox Name"), text: Binding(
                    get: { section.account.title },
                    set: { state.renameAccount(id: section.id, title: $0) }
                ))
                .textFieldStyle(.plain)
                Text(section.account.isConfigured
                    ? (section.account.emailAddress ?? section.account.subtitle)
                    : L10n.text("尚未连接", "Not Connected"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button { state.moveAccount(id: section.id, direction: -1) } label: {
                Image(systemName: "arrow.up")
            }
            .buttonStyle(.borderless)
            .disabled(index == 0)
            .help(L10n.text("上移", "Move Up"))

            Button { state.moveAccount(id: section.id, direction: 1) } label: {
                Image(systemName: "arrow.down")
            }
            .buttonStyle(.borderless)
            .disabled(index == state.sections.count - 1)
            .help(L10n.text("下移", "Move Down"))

            if state.connectingAccountID == section.id || state.isAddingIMAPAccount {
                ProgressView().controlSize(.small)
            }

            if section.account.isConfigured {
                Button(L10n.text("断开", "Disconnect")) { state.disconnect(section.account) }
            } else if section.account.provider == .imap {
                Button(L10n.text("配置", "Configure")) { imapAccountToConfigure = section.account }
            } else {
                Button(L10n.text("连接", "Connect")) {
                    Task { await state.connect(section.account) }
                }
                .disabled(
                    state.connectingAccountID != nil
                        || (section.account.provider == .gmail && !state.hasGoogleOAuthClient)
                        || (section.account.provider == .outlook && !state.hasMicrosoftClientID)
                )
            }

            Button(role: .destructive) {
                accountPendingRemoval = section.account
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help(L10n.text("移除邮箱", "Remove Mailbox"))
        }
        .padding(.vertical, 5)
    }

    private var aiTab: some View {
        Form {
            Section(L10n.text("OpenAI API", "OpenAI API")) {
                HStack {
                    SecureField(
                        state.hasOpenAIKey
                            ? L10n.text("已保存密钥（输入可替换）", "Key saved (enter to replace)")
                            : L10n.text("粘贴 API 密钥", "Paste API Key"),
                        text: $apiKey
                    )
                    .textFieldStyle(.roundedBorder)
                    Button(L10n.text("保存", "Save")) {
                        state.saveAPIKey(apiKey)
                        apiKey = ""
                    }
                    .disabled(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                if state.hasOpenAIKey {
                    Button(L10n.text("从钥匙串删除密钥", "Delete Key from Keychain"), role: .destructive) {
                        state.deleteAPIKey()
                    }
                }
            }

            Section(L10n.text("摘要模型", "Digest Model")) {
                Picker(L10n.text("模型", "Model"), selection: Binding(
                    get: { state.settings.model },
                    set: { state.setModel($0) }
                )) {
                    Text(L10n.text("GPT-5.6 Terra（均衡）", "GPT-5.6 Terra (Balanced)"))
                        .tag("gpt-5.6-terra")
                    Text(L10n.text("GPT-5.6 Luna（省费用）", "GPT-5.6 Luna (Lower Cost)"))
                        .tag("gpt-5.6-luna")
                }
            }

            Text(L10n.text(
                "邮件正文及必要的附件文字会发送给 OpenAI，以当前应用语言生成摘要和一个邮件类型；账号密码和邮箱授权令牌不会发送。",
                "Email text and necessary attachment text are sent to OpenAI to generate a digest and one mail type in the selected app language. Passwords and authorization tokens are never sent."
            ))
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }

    private var generalTab: some View {
        Form {
            Section(L10n.text("语言", "Language")) {
                Picker(L10n.text("应用语言", "Application Language"), selection: Binding(
                    get: { state.settings.language },
                    set: { state.setLanguage($0) }
                )) {
                    ForEach(AppLanguage.allCases, id: \.self) { language in
                        Text(language.displayName).tag(language)
                    }
                }
                .pickerStyle(.segmented)
            }

            Section(L10n.text("刷新", "Refresh")) {
                Toggle(L10n.text("启用定时刷新", "Enable Scheduled Refresh"), isOn: Binding(
                    get: { state.settings.scheduledRefreshEnabled },
                    set: { state.setScheduledRefreshEnabled($0) }
                ))
                ForEach(state.settings.scheduledTimes) { time in
                    HStack {
                        DatePicker(
                            L10n.text("刷新时间", "Refresh Time"),
                            selection: Binding(
                                get: { time.dateForPicker },
                                set: { state.updateScheduledTime(time, to: $0) }
                            ),
                            displayedComponents: .hourAndMinute
                        )
                        Button(role: .destructive) {
                            state.removeScheduledTime(time)
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                    }
                }
                if state.settings.scheduledTimes.count < 5 {
                    HStack {
                        DatePicker(
                            L10n.text("新时间", "New Time"),
                            selection: $newRefreshTime,
                            displayedComponents: .hourAndMinute
                        )
                        Button {
                            state.addScheduledTime(newRefreshTime)
                        } label: {
                            Label(L10n.text("添加", "Add"), systemImage: "plus.circle")
                        }
                    }
                }
                Text(L10n.text(
                    "最多5个每日时间。错过的时间不会补刷；如果全部邮箱在15分钟内刚刷新成功，也会跳过该次定时刷新。手动刷新和单邮箱重试始终保留。",
                    "Set up to five daily times. Missed times are not replayed, and a run is skipped when every mailbox refreshed successfully in the previous 15 minutes. Manual refresh and per-mailbox retry remain available."
                ))
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section(L10n.text("应用", "Application")) {
                Toggle(L10n.text("登录 Mac 时自动启动", "Launch at Mac Login"), isOn: Binding(
                    get: { state.settings.launchAtLogin },
                    set: { state.setLaunchAtLogin($0) }
                ))
                Button(L10n.text("发送测试通知", "Send Test Notification")) {
                    state.sendTestNotification()
                }
                Text(L10n.text(
                    "窗口会显示在主屏幕桌面层，并记住位置、尺寸和折叠状态。",
                    "The window stays on the main desktop layer and remembers its position, size, and expanded sections."
                ))
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section(L10n.text("Apple 日历", "Apple Calendar")) {
                Text(L10n.text(
                    "包含明确日期的摘要会显示日历按钮。应用只在本机检查时间冲突，并在你确认后创建事件。",
                    "Digests with a clear date show a calendar button. Conflicts are checked only on this Mac, and events are created only after confirmation."
                ))
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            if let message = state.settingsMessage {
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func configurationStatus(_ configured: Bool) -> some View {
        Text(configured ? L10n.text("已保存", "Saved") : L10n.text("未配置", "Not Configured"))
            .foregroundStyle(configured ? .green : .secondary)
    }

    private func providerIcon(_ provider: MailProvider) -> String {
        switch provider {
        case .gmail: "envelope.fill"
        case .outlook: "m.square.fill"
        case .imap: "envelope.badge"
        }
    }

    private func providerColor(_ provider: MailProvider) -> Color {
        switch provider {
        case .gmail: .red
        case .outlook: .blue
        case .imap: .teal
        }
    }
}
