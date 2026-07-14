import SwiftUI
import AppKit
import UniformTypeIdentifiers
import Observation

extension UTType {
    static let gyrusBookmark = UTType(exportedAs: "com.gyrus.bookmark")
    static let gyrusCollection = UTType(exportedAs: "com.gyrus.collection")
}

extension Notification.Name {
    static let showImport = Notification.Name("showImport")
    static let showCommandPalette = Notification.Name("showCommandPalette")
    static let showAddBookmark = Notification.Name("showAddBookmark")
    static let bookmarksMoved = Notification.Name("bookmarksMoved")
}

@MainActor
final class GyrusApplicationDelegate: NSObject, NSApplicationDelegate {
    var openMainWindow: (() -> Void)?
    private var mainWindow: NSWindow?
    private var mainWindowDelegate: MainWindowDelegateProxy?

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
        if mainWindow?.isVisible != true {
            showMainWindow(activate: false)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        showMainWindow()
        return false
    }

    func showMainWindow(activate: Bool = true) {
        if activate {
            NSApp.activate(ignoringOtherApps: true)
        }
        if let window = mainWindow {
            if window.isMiniaturized {
                window.deminiaturize(nil)
            }
            window.makeKeyAndOrderFront(nil)
        } else {
            openMainWindow?()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if let window = NSApp.keyWindow ?? NSApp.windows.first(where: { $0.title == "Gyrus" }) {
                    self.registerMainWindow(window)
                    window.makeKeyAndOrderFront(nil)
                }
            }
        }
    }

    func registerMainWindow(_ window: NSWindow) {
        guard mainWindow !== window else { return }
        let proxy = MainWindowDelegateProxy(forwardingTo: window.delegate)
        mainWindow = window
        mainWindowDelegate = proxy
        window.identifier = NSUserInterfaceItemIdentifier("gyrus-main-window")
        window.isReleasedWhenClosed = false
        window.delegate = proxy
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

private struct MainWindowLifecycleRegistration: ViewModifier {
    @Environment(\.openWindow) private var openWindow
    let appDelegate: GyrusApplicationDelegate

    func body(content: Content) -> some View {
        content.onAppear {
            DispatchQueue.main.async {
                if let window = NSApp.keyWindow {
                    appDelegate.registerMainWindow(window)
                }
            }
            appDelegate.openMainWindow = {
                openWindow(id: "main")
            }
        }
    }
}

@main
struct GyrusApp: App {
    @NSApplicationDelegateAdaptor(GyrusApplicationDelegate.self) private var appDelegate
    @State private var launcher = BackendLauncher.shared
    @State private var store = AppStore.shared
    @State private var bookmarkStore = AppStore.shared.bookmarksStore
    @State private var collectionStore = AppStore.shared.collectionsStore
    @State private var tagStore = AppStore.shared.tagsStore
    @State private var uiStateStore = AppStore.shared.uiStateStore
    @State private var settings = AppSettings.shared

    init() {
        // Stop backend on app quit
        let launcher = BackendLauncher.shared
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                launcher.stop()
            }
        }

        // Global search shortcut → open the command palette.
        GlobalHotkey.shared.register(id: GlobalHotkey.searchID,
                                     config: AppSettings.shared.searchHotkey) {
            DispatchQueue.main.async {
                NSApp.activate(ignoringOtherApps: true)
                NotificationCenter.default.post(name: .showCommandPalette, object: nil)
            }
        }
        // Global quick-add shortcut → floating quick-add panel (works even when
        // the main window is closed or Gyrus isn't frontmost).
        GlobalHotkey.shared.register(id: GlobalHotkey.quickAddID,
                                     config: AppSettings.shared.quickAddHotkey) {
            DispatchQueue.main.async {
                QuickAddController.shared.show()
            }
        }
    }

    private var resolvedScheme: ColorScheme? {
        switch settings.appTheme {
        case "light": return .light
        case "dark":  return .dark
        default:      return nil
        }
    }

    var body: some Scene {
        Window("Gyrus", id: "main") {
            Group {
                if launcher.isRunning {
                    ContentView()
                        .environment(bookmarkStore)
                        .environment(collectionStore)
                        .environment(tagStore)
                        .environment(uiStateStore)
                        .environment(store)
                } else {
                    StartupView()
                        .environment(launcher)
                }
            }
            .preferredColorScheme(resolvedScheme)
            .modifier(MainWindowLifecycleRegistration(appDelegate: appDelegate))
            .task {
                await launcher.start()
                if launcher.isRunning {
                    // The backend boots with default brain settings. Push the
                    // saved config (location + on/off) so the user's choice is
                    // actually applied — otherwise every launch reverts to the
                    // default ~/.gyrus/brain and ignores a disabled brain.
                    try? await APIClient.shared.updateAIBrainConfig(AppSettings.shared.aiBrainConfig)
                    await store.loadAll()
                    // Backend is confirmed up now → (re)load any favicons that a
                    // card may have requested before it was ready.
                    FaviconCache.shared.refresh()
                }
            }
            // Recover the backend connection (and favicons) when the Mac wakes
            // or the app returns to the foreground. Only after the initial start.
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                if launcher.isRunning {
                    store.uiStateStore.beginResumeGrace()
                    Task { await store.recoverConnection() }
                }
            }
            .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)) { _ in
                if launcher.isRunning {
                    store.uiStateStore.beginResumeGrace()
                    Task { await store.recoverConnection() }
                }
            }
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Import Bookmarks…") {
                    NotificationCenter.default.post(name: .showImport, object: nil)
                }
                .keyboardShortcut("i", modifiers: .command)
            }
        }

        Settings {
            SettingsView()
        }

        MenuBarExtra("Gyrus", image: "MenuBarIcon", isInserted: $settings.showMenuBarItem) {
            Button("Quick Add… (\(settings.quickAddHotkey.displayString))") {
                QuickAddController.shared.show()
            }

            Button("Open Gyrus") {
                appDelegate.showMainWindow()
            }

            SettingsLink {
                Text("Settings…")
            }

            Divider()

            Button("Quit Gyrus") {
                NSApplication.shared.terminate(nil)
            }
        }
    }
}
