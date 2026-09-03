import AppKit
import CoreGraphics
import SwiftUI

@MainActor
final class DesktopWidgetWindowController: NSWindowController {
    private let state: AppState

    init(state: AppState) {
        self.state = state

        let panel = DesktopPanel(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 620),
            styleMask: [.borderless, .resizable, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.contentViewController = NSHostingController(rootView: DesktopWidgetView(state: state))
        panel.title = L10n.text("邮件摘要", "Mail Digest")
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isMovableByWindowBackground = true
        panel.minSize = NSSize(width: 340, height: 420)
        panel.level = NSWindow.Level(
            rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1
        )
        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .stationary,
            .ignoresCycle,
            .fullScreenAuxiliary
        ]

        super.init(window: panel)

        let restoredSavedFrame = panel.setFrameUsingName(Self.frameAutosaveName)
        if !restoredSavedFrame {
            positionOnMainScreen(panel)
        }
        migrateWidgetLayoutIfNeeded(panel)
        panel.setFrameAutosaveName(Self.frameAutosaveName)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func showWidget() {
        guard let window else { return }
        if !window.isVisible {
            window.orderFrontRegardless()
        } else {
            window.orderFront(nil)
        }
    }

    func toggleWidget() {
        guard let window else { return }
        if window.isVisible {
            window.orderOut(nil)
        } else {
            window.orderFrontRegardless()
        }
    }

    private func positionOnMainScreen(_ window: NSWindow) {
        guard let screen = NSScreen.main else {
            window.center()
            return
        }
        let visible = screen.visibleFrame
        let origin = NSPoint(
            x: visible.maxX - window.frame.width - 28,
            y: visible.maxY - window.frame.height - 28
        )
        window.setFrameOrigin(origin)
    }

    private func migrateWidgetLayoutIfNeeded(_ window: NSWindow) {
        let defaults = UserDefaults.standard
        guard defaults.integer(forKey: Self.layoutVersionKey) < Self.currentLayoutVersion,
              let screen = window.screen ?? NSScreen.main
        else { return }

        let visible = screen.visibleFrame
        let oldFrame = window.frame
        let targetWidth = min(455, max(340, oldFrame.width * 0.89))
        let top = min(oldFrame.maxY, visible.maxY - 8)
        let targetBottom = visible.minY + 18
        let targetHeight = min(
            visible.height - 26,
            max(560, top - targetBottom)
        )
        var migrated = NSRect(
            x: oldFrame.minX,
            y: top - targetHeight,
            width: targetWidth,
            height: targetHeight
        )
        if migrated.maxX > visible.maxX {
            migrated.origin.x = visible.maxX - migrated.width
        }
        if migrated.minX < visible.minX {
            migrated.origin.x = visible.minX
        }
        if migrated.minY < visible.minY {
            migrated.origin.y = visible.minY
        }
        window.setFrame(migrated, display: false)
        defaults.set(Self.currentLayoutVersion, forKey: Self.layoutVersionKey)
    }

    private static let frameAutosaveName = "MailBriefDesktopWidgetFrame"
    private static let layoutVersionKey = "MailBriefDesktopWidgetLayoutVersion"
    private static let currentLayoutVersion = 2
}

private final class DesktopPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
