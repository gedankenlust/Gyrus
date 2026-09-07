import AppKit
import SwiftUI

@MainActor
final class GyrusApplicationDelegate: NSObject, NSApplicationDelegate {
    private(set) var mainWindow: NSWindow?
    private var mainWindowDelegate: MainWindowDelegateProxy?
    private var openMainWindow: (() -> Void)?
    private var pendingOpen = false
    private var isTerminating = false

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return .terminateNow }
        guard !isTerminating else { return .terminateLater }
        isTerminating = true
        Task { @MainActor in
            await BackendLauncher.shared.stopAndWait()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        ProcessInfo.processInfo.disableAutomaticTermination(
            "Gyrus remains available for its menu bar item and global shortcuts"
        )
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        guard mainWindow?.isVisible != true else { return }
        showMainWindow(activate: false)
    }

    func applicationWillUnhide(_ notification: Notification) {
        guard mainWindow?.isVisible != true else { return }
        showMainWindow(activate: false)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Do not swallow the Dock event before SwiftUI has supplied an opener.
        // Settings or Quick Add being visible does not mean the library is open.
        !showMainWindow()
    }

    func installMainWindowOpener(_ action: @escaping () -> Void) {
        openMainWindow = action
        guard pendingOpen else { return }
        pendingOpen = false
        DispatchQueue.main.async { [weak self] in
            self?.showMainWindow(activate: false)
        }
    }

    @discardableResult
    func showMainWindow(activate: Bool = true) -> Bool {
        if activate {
            NSApp.activate(ignoringOtherApps: true)
        }
        if let window = mainWindow {
            pendingOpen = false
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
            return true
        }
        guard let openMainWindow else {
            pendingOpen = true
            return false
        }
        pendingOpen = false
        openMainWindow()
        return true
    }

    /// Called only by the view attached to the main scene's actual NSWindow.
    /// Never infer ownership from NSApp.keyWindow: it may be Settings or a panel.
    func registerMainWindow(_ window: NSWindow) {
        guard mainWindow !== window else { return }
        let proxy = MainWindowDelegateProxy(forwardingTo: window.delegate)
        mainWindow = window
        mainWindowDelegate = proxy
        window.identifier = NSUserInterfaceItemIdentifier("gyrus-main-window")
        window.isReleasedWhenClosed = false
        window.delegate = proxy
        if pendingOpen {
            showMainWindow(activate: false)
        }
    }
}

@MainActor
private final class MainWindowDelegateProxy: NSObject, NSWindowDelegate {
    private weak var forwardedDelegate: NSWindowDelegate?

    init(forwardingTo delegate: NSWindowDelegate?) {
        forwardedDelegate = delegate
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }

    override func responds(to selector: Selector!) -> Bool {
        super.responds(to: selector) || forwardedDelegate?.responds(to: selector) == true
    }

    override func forwardingTarget(for selector: Selector!) -> Any? {
        if forwardedDelegate?.responds(to: selector) == true {
            return forwardedDelegate
        }
        return super.forwardingTarget(for: selector)
    }
}

/// Commands exist even on a hidden login launch, before any window appears.
/// Install the SwiftUI scene opener here instead of in the window's onAppear.
struct MainWindowCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    let appDelegate: GyrusApplicationDelegate

    var body: some Commands {
        let _ = appDelegate.installMainWindowOpener { openWindow(id: "main") }
        CommandGroup(before: .windowArrangement) {
            Button("Open Gyrus") { appDelegate.showMainWindow() }
        }
    }
}

struct MainWindowRegistration: NSViewRepresentable {
    let appDelegate: GyrusApplicationDelegate

    func makeNSView(context: Context) -> MainWindowAttachmentView {
        let view = MainWindowAttachmentView()
        view.didAttach = { [weak appDelegate] window in
            appDelegate?.registerMainWindow(window)
        }
        return view
    }

    func updateNSView(_ nsView: MainWindowAttachmentView, context: Context) {}
}

@MainActor
final class MainWindowAttachmentView: NSView {
    var didAttach: ((NSWindow) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let attachedWindow = window else { return }
        DispatchQueue.main.async { [weak self, weak attachedWindow] in
            guard let self, let attachedWindow, self.window === attachedWindow else { return }
            self.didAttach?(attachedWindow)
        }
    }
}
