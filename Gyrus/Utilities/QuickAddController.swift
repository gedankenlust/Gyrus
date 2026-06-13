import AppKit
import SwiftUI

/// Presents the Quick-Add form as a floating panel, so it works even when the
/// main Gyrus window is closed or the app isn't frontmost (triggered by the
/// global hotkey or the menu-bar item).
@MainActor
final class QuickAddController {
    static let shared = QuickAddController()

    private var panel: NSPanel?

    func show() {
        // Bring the app forward so the panel can become key and accept input.
        NSApp.activate(ignoringOtherApps: true)

        if let panel = panel {
            panel.makeKeyAndOrderFront(nil)
            panel.center()
            return
        }

        let content = QuickAddPanel(onClose: { [weak self] in self?.close() })
            .environment(\.locale, AppSettings.shared.resolvedLocale)
        let hosting = NSHostingView(rootView: content)

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 220),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.contentView = hosting
        panel.center()
        panel.makeKeyAndOrderFront(nil)

        self.panel = panel
    }

    func close() {
        panel?.orderOut(nil)
    }
}
