import Foundation
import SwiftUI
import Observation
import Carbon
import os

public struct HotkeyConfig: Codable, Equatable {
    public var keyCode: UInt32
    public var modifiers: UInt32
    public var keyString: String
    
    public static let defaultSearch = HotkeyConfig(keyCode: 49, modifiers: UInt32(optionKey), keyString: "Space")

    /// Quick-add default: ⌃⌥⌘B. A three-modifier combo with a letter is
    /// practically never claimed by the system (⌥Space is already the search
    /// shortcut, ⌘Space is Spotlight). keyCode 11 = "B".
    public static let defaultQuickAdd = HotkeyConfig(
        keyCode: 11,
        modifiers: UInt32(controlKey) | UInt32(optionKey) | UInt32(cmdKey),
        keyString: "B"
    )
    
    public var displayString: String {
        var str = ""
        if modifiers & UInt32(controlKey) != 0 { str += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { str += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { str += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { str += "⌘" }
        
        let displayKey = keyString.isEmpty ? "Key \(keyCode)" : keyString
        return str + displayKey
    }
}

/// Central, typed store for all user settings.
///
/// Every setting is a **stored** property (not computed) so SwiftUI's
/// `@Observable` can track changes — two-way bindings update the UI live and
/// changes propagate to other views (e.g. a theme switch re-renders the app).
/// Each `didSet` persists to `UserDefaults`; values are loaded once in `init`.
@Observable
public final class AppSettings {
    public static let shared = AppSettings()

    private let defaults = UserDefaults.standard

    // MARK: - Keys
    private enum Keys {
        static let appLanguage = "appLanguage"
        static let appTheme = "appTheme"
        static let confirmDelete = "confirmDelete"
        static let defaultExportFmt = "defaultExportFmt"
        static let defaultPreviewTab = "defaultPreviewTab"
        static let cardLayout = "cardLayout"
        static let tagSortMode = "tagSortMode"
        static let enableReadStatus = "enableReadStatus"
        static let aiBrainConfig = "aiBrainConfig"
        static let didCompleteBrainOnboarding = "didCompleteBrainOnboarding"
        static let searchHotkey = "searchHotkey"
        static let quickAddHotkey = "quickAddHotkey"
        static let showMenuBarItem = "showMenuBarItem"
    }

    // MARK: - General Settings

    /// UI language: "system", "en" or "de". Applied via the standard macOS
    /// mechanism — a per-app AppleLanguages override that takes effect on the
    /// next launch (Settings offers to relaunch). No Bundle swizzling: the
    /// old object_setClass hack broke "System Language" once already.
    public var appLanguage: String {
        didSet {
            defaults.set(appLanguage, forKey: Keys.appLanguage)
            if appLanguage == "system" {
                defaults.removeObject(forKey: "AppleLanguages")
            } else {
                defaults.set([appLanguage], forKey: "AppleLanguages")
            }
        }
    }

    public var appTheme: String {
        didSet { defaults.set(appTheme, forKey: Keys.appTheme) }
    }

    public var confirmDelete: Bool {
        didSet { defaults.set(confirmDelete, forKey: Keys.confirmDelete) }
    }

    /// Whether the read/unread feature is shown at all (dots, Unread view,
    /// toggle button, context-menu action). Off = a plain bookmark manager.
    public var enableReadStatus: Bool {
        didSet { defaults.set(enableReadStatus, forKey: Keys.enableReadStatus) }
    }

    public var defaultExportFmt: String {
        didSet { defaults.set(defaultExportFmt, forKey: Keys.defaultExportFmt) }
    }

    /// Which preview tab a bookmark opens to (raw value of PreviewTab).
    public var defaultPreviewTab: String {
        didSet { defaults.set(defaultPreviewTab, forKey: Keys.defaultPreviewTab) }
    }

    static func canonicalPreviewTab(_ value: String?) -> String {
        switch value {
        case "Design", "Snapshot": return "Design"
        case "AI Brain": return "AI Brain"
        case "Notes": return "Notes"
        case "Page", "Info", "Reader", "Web": return "Page"
        default: return "Page"
        }
    }

    /// Grid card layout: "titleFirst" (title on top, URL below) or "urlFirst".
    public var cardLayout: String {
        didSet { defaults.set(cardLayout, forKey: Keys.cardLayout) }
    }

    /// Sidebar tag order: "name" (alphabetical) or "count" (most used first).
    public var tagSortMode: String {
        didSet { defaults.set(tagSortMode, forKey: Keys.tagSortMode) }
    }

    /// Whether the one-time AI-Brain setup prompt has been shown.
    public var didCompleteBrainOnboarding: Bool {
        didSet { defaults.set(didCompleteBrainOnboarding, forKey: Keys.didCompleteBrainOnboarding) }
    }

    public var searchHotkey: HotkeyConfig {
        didSet {
            if let data = try? JSONEncoder().encode(searchHotkey) {
                defaults.set(data, forKey: Keys.searchHotkey)
            }
            // Re-register with the same callback; remember if the combo is taken.
            searchHotkeyConflict = !GlobalHotkey.shared.reregister(
                id: GlobalHotkey.searchID, config: searchHotkey)
        }
    }

    public var quickAddHotkey: HotkeyConfig {
        didSet {
            if let data = try? JSONEncoder().encode(quickAddHotkey) {
                defaults.set(data, forKey: Keys.quickAddHotkey)
            }
            quickAddHotkeyConflict = !GlobalHotkey.shared.reregister(
                id: GlobalHotkey.quickAddID, config: quickAddHotkey)
        }
    }

    /// Show the Gyrus icon in the macOS menu bar (quick-add + open). Default on.
    public var showMenuBarItem: Bool {
        didSet { defaults.set(showMenuBarItem, forKey: Keys.showMenuBarItem) }
    }

    /// Transient (not persisted): true when the last re-registration of the
    /// corresponding hotkey failed because the combination is already taken.
    /// Drives an inline warning in Settings.
    public var searchHotkeyConflict: Bool = false
    public var quickAddHotkeyConflict: Bool = false

    // MARK: - AI Brain Settings

    public var aiBrainConfig: AIBrainConfig {
        didSet {
            if let data = try? JSONEncoder().encode(aiBrainConfig) {
                defaults.set(data, forKey: Keys.aiBrainConfig)
            }
            syncWithBackend(aiBrainConfig)
        }
    }

    // MARK: - Localization

    /// Localize a key for AppKit views and plain `String`s (sidebar outline,
    /// navigation titles). With the relaunch-based language switch the process
    /// runs entirely in the launch language, so the standard lookup is correct.
    func localized(_ value: String.LocalizationValue) -> String {
        String(localized: value)
    }

    /// The effective UI language ("en"/"de") sent to the backend so AI
    /// features (auto-tagging) generate content in the language the user
    /// actually reads, not always English. "system" resolves to the real
    /// macOS language, same as the app itself does at launch.
    public var effectiveLanguageCode: String {
        (appLanguage == "en" || appLanguage == "de") ? appLanguage : Bundle.systemLanguageCode()
    }

    // MARK: - Init

    private init() {
        // Load every setting once. Assignments during init do NOT fire didSet,
        // so this neither re-persists nor triggers a spurious backend push.
        let d = UserDefaults.standard
        appLanguage = d.string(forKey: Keys.appLanguage) ?? "system"
        appTheme = d.string(forKey: Keys.appTheme) ?? "system"
        confirmDelete = d.object(forKey: Keys.confirmDelete) as? Bool ?? true
        enableReadStatus = d.object(forKey: Keys.enableReadStatus) as? Bool ?? true
        defaultExportFmt = d.string(forKey: Keys.defaultExportFmt) ?? "markdown"
        let storedPreviewTab = d.string(forKey: Keys.defaultPreviewTab)
        let canonicalPreviewTab = Self.canonicalPreviewTab(storedPreviewTab)
        defaultPreviewTab = canonicalPreviewTab
        if storedPreviewTab != canonicalPreviewTab {
            d.set(canonicalPreviewTab, forKey: Keys.defaultPreviewTab)
        }
        cardLayout = d.string(forKey: Keys.cardLayout) ?? "titleFirst"
        tagSortMode = d.string(forKey: Keys.tagSortMode) ?? "name"
        didCompleteBrainOnboarding = d.bool(forKey: Keys.didCompleteBrainOnboarding)
        if let data = d.data(forKey: Keys.searchHotkey),
           let config = try? JSONDecoder().decode(HotkeyConfig.self, from: data) {
            searchHotkey = config
        } else {
            searchHotkey = .defaultSearch
        }
        if let data = d.data(forKey: Keys.quickAddHotkey),
           let config = try? JSONDecoder().decode(HotkeyConfig.self, from: data) {
            quickAddHotkey = config
        } else {
            quickAddHotkey = .defaultQuickAdd
        }
        showMenuBarItem = d.object(forKey: Keys.showMenuBarItem) as? Bool ?? true
        if let data = d.data(forKey: Keys.aiBrainConfig),
           let config = try? JSONDecoder().decode(AIBrainConfig.self, from: data) {
            aiBrainConfig = config
        } else {
            aiBrainConfig = AIBrainConfig()
        }
        // Clear a stale per-app AppleLanguages override left by an explicit
        // language choice if the setting is (back on) "system" — otherwise the
        // override would silently pin the old language forever.
        if appLanguage == "system" {
            defaults.removeObject(forKey: "AppleLanguages")
        }
    }

    // MARK: - Helpers

    /// Wraps a user-chosen directory in a dedicated "Gyrus Brain" subfolder, so
    /// enabling the brain never scatters _Unsorted/, Inbox/ etc. directly into
    /// the picked folder (e.g. the Desktop). Idempotent if already wrapped.
    public static func brainRoot(forChosenDirectory url: URL) -> String {
        if url.lastPathComponent == "Gyrus Brain" { return url.path }
        return url.appendingPathComponent("Gyrus Brain").path
    }

    private func syncWithBackend(_ config: AIBrainConfig) {
        Task {
            do {
                try await APIClient.shared.updateAIBrainConfig(config)
            } catch {
                // Not user-facing on purpose: this also fires during startup
                // before the backend is up, and the config is re-pushed on
                // launch (GyrusApp.task) anyway.
                Logger(subsystem: "com.gyrus.app", category: "settings")
                    .warning("Failed to sync AI Brain config: \(error.localizedDescription)")
            }
        }
    }
}

// MARK: - Language switching (relaunch-based)

extension Bundle {
    /// The OS-level preferred language ("de"/"en"), read from the *global*
    /// domain so a per-app AppleLanguages override never shadows it.
    static func systemLanguageCode() -> String {
        if let langs = CFPreferencesCopyValue(
            "AppleLanguages" as CFString,
            kCFPreferencesAnyApplication,
            kCFPreferencesCurrentUser,
            kCFPreferencesAnyHost
        ) as? [String], langs.contains(where: { $0.hasPrefix("de") }) {
            return "de"
        }
        return "en"
    }
}

extension AppSettings {
    /// Relaunch Gyrus so a changed language takes effect. `open -n` receives the
    /// bundle path as a real argument, never as shell source.
    public static func relaunchApp() {
        let path = Bundle.main.bundlePath
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = ["-n", path]
        try? task.run()
        NSApp.terminate(nil)
    }
}
