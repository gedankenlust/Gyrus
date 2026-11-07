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

    private var bookmarkStore: BookmarkStore { appStore.bookmarksStore }
    private var uiState: UIStateStore { appStore.uiStateStore }

    private func libraryOwnsKeyboard() -> Bool {
        LibraryCommandRouting.libraryOwnsKeyboard(mainWindow: appDelegate.mainWindow)
    }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Bookmark…") {
                appDelegate.showMainWindow()
                NotificationCenter.default.post(name: .showAddBookmark, object: nil)
            }
            .keyboardShortcut("n", modifiers: .command)
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
                    appStore.requestDeleteSelected()
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
    }
}
