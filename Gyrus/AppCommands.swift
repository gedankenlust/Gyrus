import SwiftUI
import AppKit
import WebKit

/// Decides whether a library shortcut (⌘A, ⌘Z, ⌘⌫, Esc) belongs to the
/// bookmark list or to whatever the user is typing in.
///
/// Menu key equivalents are handled before the first responder sees the key,
/// so a library command bound to ⌘Z would otherwise swallow undo in the search
/// field, and ⌘⌫ in a notes field would trash the selected bookmarks.
@MainActor
enum LibraryCommandRouting {
    /// The main window is key and no text field, text view or web page owns
    /// the keyboard.
    static func libraryOwnsKeyboard(mainWindow: NSWindow?) -> Bool {
        guard let window = NSApp.keyWindow, let mainWindow, window === mainWindow else { return false }
        return !isEditingText(in: window)
    }

    static func isEditingText(in window: NSWindow) -> Bool {
        guard let responder = window.firstResponder else { return false }
        // Field editors of text fields and search fields are NSTextViews too.
        if responder is NSText { return true }
        if let view = responder as? NSView, view.enclosing(WKWebView.self) != nil { return true }
        return false
    }

    /// Hand a standard edit action to the responder chain, as if our menu
    /// item did not exist.
    static func forward(_ action: Selector) {
        NSApp.sendAction(action, to: nil, from: nil)
    }

    /// Focus the toolbar search field. `.searchable` gains a focus binding only
    /// in macOS 15, so on 14 reach the NSSearchToolbarItem SwiftUI creates.
    static func focusToolbarSearch(in window: NSWindow?) {
        guard let window,
              let item = window.toolbar?.items.lazy.compactMap({ $0 as? NSSearchToolbarItem }).first
        else { return }
        window.makeKeyAndOrderFront(nil)
        item.beginSearchInteraction()
    }
}

private extension NSView {
    func enclosing<T: NSView>(_ type: T.Type) -> T? {
        var view: NSView? = self
        while let current = view {
            if let match = current as? T { return match }
            view = current.superview
        }
        return nil
    }
}

/// Edit and Bookmark menus. Every library shortcut is a visible, discoverable
/// menu item that falls back to the standard text behavior while typing.
struct LibraryCommands: Commands {
    let appDelegate: GyrusApplicationDelegate
    let appStore: AppStore
    /// Shared with ContentView, which presents the inspector.
    @AppStorage(InspectorVisibility.storageKey) private var showInspector = true

    private var bookmarkStore: BookmarkStore { appStore.bookmarksStore }
    private var uiState: UIStateStore { appStore.uiStateStore }

    private func libraryOwnsKeyboard() -> Bool {
        LibraryCommandRouting.libraryOwnsKeyboard(mainWindow: appDelegate.mainWindow)
    }

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About Gyrus") { AboutPanel.show() }
        }

        CommandGroup(replacing: .newItem) {
            Button("New Bookmark…") {
                appDelegate.showMainWindow()
                NotificationCenter.default.post(name: .showAddBookmark, object: nil)
            }
            .keyboardShortcut("n", modifiers: .command)
        }

        CommandGroup(after: .newItem) {
            Button("Import Bookmarks…") {
                appDelegate.showMainWindow()
                NotificationCenter.default.post(name: .showImport, object: nil)
            }
            .keyboardShortcut("i", modifiers: .command)
            Button("Export Bookmarks…") {
                appDelegate.showMainWindow()
                NotificationCenter.default.post(name: .showExport, object: nil)
            }
            .keyboardShortcut("e", modifiers: [.command, .shift])
        }

        CommandGroup(replacing: .textEditing) {
            Button("Find Bookmarks…") {
                appDelegate.showMainWindow()
                LibraryCommandRouting.focusToolbarSearch(in: appDelegate.mainWindow)
            }
            .keyboardShortcut("f", modifiers: .command)
        }

        CommandGroup(after: .sidebar) {
            Button(showInspector ? "Hide Inspector" : "Show Inspector") {
                showInspector.toggle()
            }
            .keyboardShortcut("i", modifiers: [.command, .option])
        }

        CommandGroup(replacing: .undoRedo) {
            Button(uiState.undoAction != nil ? "Undo Delete" : "Undo") {
                if libraryOwnsKeyboard(), let undo = uiState.undoAction {
                    undo()
                    uiState.undoMessage = nil
                    uiState.undoAction = nil
                } else {
                    LibraryCommandRouting.forward(Selector(("undo:")))
                }
            }
            .keyboardShortcut("z", modifiers: .command)
            Button("Redo") {
                LibraryCommandRouting.forward(Selector(("redo:")))
            }
            .keyboardShortcut("z", modifiers: [.command, .shift])
        }

        CommandGroup(replacing: .pasteboard) {
            Button("Cut") { LibraryCommandRouting.forward(#selector(NSText.cut(_:))) }
                .keyboardShortcut("x", modifiers: .command)
            Button("Copy") { LibraryCommandRouting.forward(#selector(NSText.copy(_:))) }
                .keyboardShortcut("c", modifiers: .command)
            Button("Paste") { LibraryCommandRouting.forward(#selector(NSText.paste(_:))) }
                .keyboardShortcut("v", modifiers: .command)
            Button("Paste and Match Style") {
                LibraryCommandRouting.forward(#selector(NSTextView.pasteAsPlainText(_:)))
            }
            .keyboardShortcut("v", modifiers: [.command, .option, .shift])
            Button("Delete") { LibraryCommandRouting.forward(#selector(NSText.delete(_:))) }
            Button("Select All") {
                if libraryOwnsKeyboard() {
                    Task { await appStore.selectAllInCurrentView() }
                } else {
                    LibraryCommandRouting.forward(#selector(NSText.selectAll(_:)))
                }
            }
            .keyboardShortcut("a", modifiers: .command)
        }

        CommandMenu("Bookmark") {
            Button("Quick Search…") {
                appDelegate.showMainWindow()
                NotificationCenter.default.post(name: .showCommandPalette, object: nil)
            }
            .keyboardShortcut("k", modifiers: .command)

            Divider()

            Button("Open in Browser") {
                guard libraryOwnsKeyboard() else { return }
                appStore.requestOpenInBrowser(ids: bookmarkStore.selectedIds)
            }
            .keyboardShortcut("o", modifiers: .command)
            .disabled(bookmarkStore.selectedIds.isEmpty)

            Button(appStore.collectionsStore.showTrash ? "Delete Permanently…" : "Move to Trash") {
                if libraryOwnsKeyboard() {
                    appStore.trash.requestDeleteSelected()
                } else {
                    LibraryCommandRouting.forward(#selector(NSResponder.deleteToBeginningOfLine(_:)))
                }
            }
            .keyboardShortcut(.delete, modifiers: .command)
            .disabled(bookmarkStore.selectedIds.isEmpty)

            Button("Deselect All") {
                bookmarkStore.selectedIds.removeAll()
                bookmarkStore.selectedBookmark = nil
            }
            .disabled(bookmarkStore.selectedIds.isEmpty)
        }

        CommandMenu("Library") {
            let linkCheckRunning = appStore.jobs.linkCheckStatus?.running == true
            let metadataRunning = appStore.jobs.metadataRefreshStatus?.running == true
            Button(linkCheckRunning ? "Checking Links…" : "Check All Links") {
                Task { await appStore.jobs.startLinkCheck() }
            }
            .disabled(linkCheckRunning)
            .help("Finds dead links (404, timeout). Takes a few minutes for large collections.")

            Button(metadataRunning ? "Refreshing Metadata…" : "Refresh All Metadata") {
                Task { await appStore.jobs.startMetadataRefresh() }
            }
            .disabled(metadataRunning)
            .help("Re-fetches favicons, descriptions and preview images for every bookmark.")

            if metadataRunning {
                Button("Stop Metadata Refresh") {
                    Task { await appStore.jobs.cancelMetadataRefresh() }
                }
            }
        }
    }
}

enum InspectorVisibility {
    static let storageKey = "showInspector"
}

/// The standard About panel, with the links and credits that used to be a
/// separate About tab in Settings.
@MainActor
enum AboutPanel {
    static func show() {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? ""
        let channel = (info["GyrusReleaseChannel"] as? String).flatMap { $0.isEmpty ? nil : $0 }

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        let text: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: paragraph,
        ]
        func link(_ title: String, _ url: String) -> NSAttributedString {
            NSAttributedString(string: title, attributes: [
                .font: font, .link: URL(string: url) as Any, .paragraphStyle: paragraph,
            ])
        }

        let credits = NSMutableAttributedString()
        credits.append(NSAttributedString(string: String(localized: "Local-first bookmark manager for macOS") + "\n\n", attributes: text))
        credits.append(link(String(localized: "View Source on GitHub"), "https://github.com/gedankenlust/Gyrus"))
        credits.append(NSAttributedString(string: "  ·  ", attributes: text))
        credits.append(link(String(localized: "Report an Issue"), "https://github.com/gedankenlust/Gyrus/issues"))
        credits.append(NSAttributedString(string: "  ·  ", attributes: text))
        credits.append(link(String(localized: "MIT License"), "https://opensource.org/licenses/MIT"))
        credits.append(NSAttributedString(
            string: "\n\n" + String(localized: "Built with SwiftUI, FastAPI, SQLAlchemy, BeautifulSoup4, and Readability-lxml."),
            attributes: text))

        var options: [NSApplication.AboutPanelOptionKey: Any] = [.credits: credits]
        if let channel { options[.applicationVersion] = "\(version) \(channel)" }
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: options)
    }
}
