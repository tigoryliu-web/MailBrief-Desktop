import SwiftUI

struct DesktopWidgetView: View {
    @ObservedObject var state: AppState
    @State private var showingIMAPSetup = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.45)
            content
        }
        .frame(minWidth: 340, idealWidth: 430, minHeight: 420, idealHeight: 620)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(.white.opacity(0.16), lineWidth: 1)
        }
        .padding(10)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .scaledToFit()
            .frame(width: 36, height: 36)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.text("邮件摘要", "Mail Digest"))
                    .font(.headline)
                Text(lastUpdatedText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                Task { await state.refresh(trigger: .manual) }
            } label: {
                headerControlLabel(systemName: "arrow.clockwise", weight: .semibold)
                    .rotationEffect(state.isRefreshing ? .degrees(360) : .zero)
                    .animation(
                        state.isRefreshing
                            ? .linear(duration: 0.9).repeatForever(autoreverses: false)
                            : .default,
                        value: state.isRefreshing
                    )
            }
            .buttonStyle(.plain)
            .disabled(state.isRefreshing)
            .help(L10n.text("立即刷新", "Refresh Now"))

            Menu {
                Button(L10n.text("设置…", "Settings…")) {
                    AppCommands.openSettings()
                }
                Divider()
                Button(L10n.text("退出邮件摘要", "Quit Mail Digest")) {
                    NSApp.terminate(nil)
                }
            } label: {
                headerControlLabel(systemName: "ellipsis", weight: .bold)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(L10n.text("更多", "More"))
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    private func headerControlLabel(
        systemName: String,
        weight: Font.Weight
    ) -> some View {
        ZStack {
            Circle()
                .fill(.primary.opacity(0.07))
            Image(systemName: systemName)
                .font(.system(size: 14, weight: weight))
        }
        .frame(width: 30, height: 30)
        .contentShape(Circle())
    }

    @ViewBuilder
    private var content: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                if state.sections.allSatisfy({ $0.items.isEmpty }) {
                    emptyState
                } else if state.isPreviewing {
                    previewBanner
                }

                ForEach(state.sections) { section in
                    AccountSectionView(
                        section: section,
                        isExpanded: state.expandedAccountIDs.contains(section.id),
                        toggleExpanded: { state.toggleExpanded(accountID: section.id) },
                        toggleCompletion: { state.toggleCompletion(itemID: $0, accountID: section.id) },
                        openOriginal: { state.openOriginal($0) },
                        addToCalendar: {
                            let item = $0
                            Task {
                                await state.addToCalendar(itemID: item.id, accountID: section.id)
                            }
                        },
                        isAddingToCalendar: { state.calendarItemIDsAdding.contains($0) },
                        calendarError: { state.calendarErrors[$0] },
                        retry: { state.retry(accountID: section.id) }
                    )
                }

                Menu {
                    Button(L10n.text("添加 Gmail", "Add Gmail")) {
                        Task { await state.addOAuthAccount(provider: .gmail) }
                    }
                    Button(L10n.text("添加 Outlook", "Add Outlook")) {
                        Task { await state.addOAuthAccount(provider: .outlook) }
                    }
                    Button(L10n.text("添加其他邮箱（IMAP）", "Add Other Mail (IMAP)")) {
                        showingIMAPSetup = true
                    }
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 16, weight: .semibold))
                        .frame(width: 34, height: 34)
                        .background(.primary.opacity(0.07), in: Circle())
                        .contentShape(Circle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .disabled(state.sections.count >= 5)
                .help(state.sections.count >= 5
                    ? L10n.text("最多可添加5个邮箱", "Up to five mailboxes")
                    : L10n.text("添加邮箱", "Add Mailbox"))
                .padding(.vertical, 4)
            }
            .padding(14)
        }
        .alert(item: $state.calendarConflictPrompt) { prompt in
            Alert(
                title: Text(L10n.text("日程冲突", "Calendar Conflict")),
                message: Text(prompt.message),
                primaryButton: .default(Text(L10n.text("依然添加", "Add Anyway"))) {
                    Task { await state.confirmCalendarConflict(prompt) }
                },
                secondaryButton: .cancel(Text(L10n.text("取消", "Cancel"))) {
                    state.cancelCalendarConflict()
                }
            )
        }
        .sheet(isPresented: $showingIMAPSetup) {
            IMAPSetupView(state: state)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "envelope.badge")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.secondary)
            Text(L10n.text("还没有邮件摘要", "No Mail Digests Yet"))
                .font(.headline)
            Text(L10n.text(
                "配置邮箱后，首次同步会读取最近24小时的收件箱。",
                "After you connect a mailbox, the first refresh reads the previous 24 hours."
            ))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button(L10n.text("预览界面示例", "Preview Sample")) {
                state.loadPreviewData()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity)
        .padding(20)
        .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 15))
    }

    private var previewBanner: some View {
        HStack(spacing: 9) {
            Image(systemName: "eye.fill")
                .foregroundStyle(.blue)
            Text(L10n.text("正在预览示例数据", "Previewing Sample Data"))
                .font(.caption.weight(.semibold))
            Spacer()
            Button(L10n.text("结束预览", "End Preview")) {
                state.clearPreviewData()
            }
            .font(.caption)
            .buttonStyle(.borderless)
        }
        .padding(11)
        .background(.blue.opacity(0.09), in: RoundedRectangle(cornerRadius: 12))
    }

    private var lastUpdatedText: String {
        if state.isRefreshing { return L10n.text("正在整理新邮件…", "Organizing new mail…") }
        guard let date = state.lastRefresh else { return L10n.text("尚未更新", "Not Updated Yet") }
        return L10n.text("上次更新 \(L10n.dateTime(date, includeDate: false))", "Last updated \(L10n.dateTime(date, includeDate: false))")
    }
}

private struct AccountSectionView: View {
    let section: AccountSection
    let isExpanded: Bool
    let toggleExpanded: () -> Void
    let toggleCompletion: (UUID) -> Void
    let openOriginal: (DigestItem) -> Void
    let addToCalendar: (DigestItem) -> Void
    let isAddingToCalendar: (UUID) -> Bool
    let calendarError: (UUID) -> String?
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Button(action: toggleExpanded) {
                HStack(spacing: 10) {
                    Image(systemName: iconName)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(iconColor)
                        .frame(width: 26, height: 26)
                        .background(iconColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))

                    VStack(alignment: .leading, spacing: 1) {
                        Text(section.account.title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                        Text(sectionSubtitle)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    if !section.items.isEmpty {
                        Text("\(section.items.filter { !$0.isCompleted }.count)")
                            .font(.caption.monospacedDigit().weight(.semibold))
                            .foregroundStyle(.secondary)
                    }

                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .contentShape(Rectangle())
                .padding(12)
            }
            .buttonStyle(.plain)

            if isExpanded {
                Divider().padding(.horizontal, 12)

                switch section.syncStatus {
                case .failed(let message):
                    SyncErrorView(message: message, retry: retry)
                case .requiresSetup:
                    SetupRequiredView()
                default:
                    if section.items.isEmpty {
                        Text(L10n.text("没有新内容", "No New Items"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(14)
                    } else {
                        VStack(spacing: 0) {
                            ForEach(Array(section.items.enumerated()), id: \.element.id) { index, item in
                                DigestRow(
                                    item: item,
                                    toggleCompletion: { toggleCompletion(item.id) },
                                    openOriginal: { openOriginal(item) },
                                    addToCalendar: { addToCalendar(item) },
                                    isAddingToCalendar: isAddingToCalendar(item.id),
                                    calendarError: calendarError(item.id)
                                )
                                if index < section.items.count - 1 {
                                    Divider().padding(.leading, 54)
                                }
                            }
                        }
                    }
                }
            }
        }
        .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
    }

    private var iconName: String {
        switch section.account.provider {
        case .gmail: "envelope.fill"
        case .outlook: "m.square.fill"
        case .imap: "envelope.badge.shield.half.filled.fill"
        }
    }

    private var iconColor: Color {
        switch section.account.provider {
        case .gmail: .red
        case .outlook: .blue
        case .imap: .teal
        }
    }

    private var sectionSubtitle: String {
        switch section.syncStatus {
        case .refreshing: L10n.text("正在同步", "Syncing")
        case .failed: L10n.text("同步失败", "Sync Failed")
        case .requiresSetup: L10n.text("等待配置", "Setup Required")
        case .idle:
            section.lastSuccessfulRefresh == nil
                ? section.account.subtitle
                : L10n.text(
                    "更新于 \(L10n.dateTime(section.lastSuccessfulRefresh!, includeDate: false))",
                    "Updated \(L10n.dateTime(section.lastSuccessfulRefresh!, includeDate: false))"
                )
        }
    }
}

private struct DigestRow: View {
    let item: DigestItem
    let toggleCompletion: () -> Void
    let openOriginal: () -> Void
    let addToCalendar: () -> Void
    let isAddingToCalendar: Bool
    let calendarError: String?
    @State private var isHovered = false

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            Button(action: openOriginal) {
                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 7) {
                        PriorityBadge(priority: item.priority)
                        if let mailType = item.mailType {
                            MailTypeBadge(mailType: mailType)
                        }
                        if let deadline = item.deadline {
                            Text(deadlineText(deadline))
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(deadline < .now ? .red : .secondary)
                        }
                    }

                    Text(item.summary)
                        .font(.system(size: 13.5, weight: .medium))
                        .foregroundStyle(item.isCompleted ? .secondary : .primary)
                        .strikethrough(item.isCompleted, color: .secondary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)

                    Text("\(item.sender) · \(L10n.dateTime(item.receivedAt))")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)

                    if let calendarError {
                        Text(calendarError)
                            .font(.caption2)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(L10n.text("打开原邮件", "Open Original Email"))

            VStack(spacing: 10) {
                if item.deadline != nil {
                    if item.calendarEventIdentifier != nil {
                        Image(systemName: "calendar.badge.checkmark")
                            .font(.system(size: 17, weight: .medium))
                            .foregroundStyle(.green)
                            .help(L10n.text("已添加到 Apple 日历", "Added to Apple Calendar"))
                    } else if isAddingToCalendar {
                        ProgressView()
                            .controlSize(.small)
                            .frame(width: 21, height: 21)
                            .help(L10n.text("正在检查日程冲突", "Checking Calendar Conflicts"))
                    } else {
                        Button(action: addToCalendar) {
                            Image(systemName: "calendar.badge.plus")
                                .font(.system(size: 17, weight: .medium))
                                .foregroundStyle(.blue)
                        }
                        .buttonStyle(.plain)
                        .help(L10n.text("添加到 Apple 日历", "Add to Apple Calendar"))
                    }
                }

                Button(action: toggleCompletion) {
                    Image(systemName: item.isCompleted ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 21, weight: .regular))
                        .foregroundStyle(item.isCompleted ? .green : .secondary)
                        .symbolRenderingMode(.hierarchical)
                }
                .buttonStyle(.plain)
                .help(item.isCompleted
                    ? L10n.text("恢复为未完成", "Mark Incomplete")
                    : L10n.text("标记为完成", "Mark Complete"))
            }
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 12)
        .background(isHovered ? Color.primary.opacity(0.035) : Color.clear)
        .onHover { isHovered = $0 }
        .opacity(item.isCompleted ? 0.72 : 1)
    }

    private func deadlineText(_ deadline: Date) -> String {
        if deadline < .now {
            return L10n.text("已逾期", "Overdue")
        }
        let timeStyle: Date.FormatStyle.TimeStyle = item.deadlineHasTime == true
            ? .shortened
            : .omitted
        let formatted = deadline.formatted(date: .abbreviated, time: timeStyle)
        return L10n.text("截止 \(formatted)", "Due \(formatted)")
    }
}

private struct MailTypeBadge: View {
    let mailType: MailType

    var body: some View {
        Text(mailType.displayName)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.secondary.opacity(0.10), in: Capsule())
            .lineLimit(1)
    }
}

private struct PriorityBadge: View {
    let priority: DigestPriority

    var body: some View {
        Text(priority.displayName)
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.12), in: Capsule())
    }

    private var color: Color {
        switch priority {
        case .urgent: .red
        case .important: .orange
        case .normal: .secondary
        }
    }
}

private struct SyncErrorView: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer()
            Button(L10n.text("重试", "Retry"), action: retry)
                .font(.caption.weight(.semibold))
                .buttonStyle(.borderless)
        }
        .padding(13)
    }
}

private struct SetupRequiredView: View {
    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "person.crop.circle.badge.plus")
                .foregroundStyle(.secondary)
            Text(L10n.text(
                "请从菜单栏的“设置”完成账号授权。",
                "Open Settings from the menu bar to finish account authorization."
            ))
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(13)
    }
}
