import AppKit
import SwiftUI

@MainActor
enum AppCommands {
    static var openSettings: () -> Void = {}
    static var refreshMenus: () -> Void = {}
}

@main
enum MailDigestDesktopMain {
    @MainActor
    static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) {
            application.run()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let state: AppState
    private var widgetController: DesktopWidgetWindowController?
    private var settingsWindow: NSWindow?
    private var statusItem: NSStatusItem?
    private var refreshScheduler: RefreshScheduler?

    override init() {
        state = AppState(demoMode: CommandLine.arguments.contains("--demo"))
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let iconURL = Bundle.main.url(forResource: "AppIcon-1024", withExtension: "png"),
           let icon = NSImage(contentsOf: iconURL) {
            NSApp.applicationIconImage = icon
        }

        widgetController = DesktopWidgetWindowController(state: state)
        AppCommands.openSettings = { [weak self] in
            self?.openSettings()
        }
        AppCommands.refreshMenus = { [weak self] in
            self?.configureStatusItem()
            self?.settingsWindow?.title = L10n.text("邮件摘要设置", "Mail Digest Settings")
        }
        configureStatusItem()
        widgetController?.showWidget()

        Task {
            await state.start()
            refreshScheduler = RefreshScheduler(state: state)
            refreshScheduler?.start()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    private func configureStatusItem() {
        let item = statusItem ?? NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(
            systemSymbolName: "tray.full.fill",
            accessibilityDescription: L10n.text("邮件摘要", "Mail Digest")
        )
        item.button?.toolTip = L10n.text("邮件摘要", "Mail Digest")

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: L10n.text("显示或隐藏桌面摘要", "Show or Hide Mail Digest"), action: #selector(toggleWidget), keyEquivalent: "d"))
        menu.addItem(NSMenuItem(title: L10n.text("立即刷新", "Refresh Now"), action: #selector(refreshNow), keyEquivalent: "r"))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: L10n.text("设置…", "Settings…"), action: #selector(openSettings), keyEquivalent: ","))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: L10n.text("退出邮件摘要", "Quit Mail Digest"), action: #selector(quit), keyEquivalent: "q"))
        menu.items.forEach { $0.target = self }
        item.menu = menu
        statusItem = item
    }

    @objc private func toggleWidget() {
        widgetController?.toggleWidget()
    }

    @objc private func refreshNow() {
        Task { await state.refresh(trigger: .manual) }
    }

    @objc func openSettings() {
        if settingsWindow == nil {
            let controller = NSHostingController(rootView: SettingsView(state: state))
            let window = NSWindow(contentViewController: controller)
            window.title = L10n.text("邮件摘要设置", "Mail Digest Settings")
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }

        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
