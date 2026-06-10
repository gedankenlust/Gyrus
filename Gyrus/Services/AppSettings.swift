import Foundation
import SwiftUI
import Observation
import Carbon

public struct HotkeyConfig: Codable, Equatable {
    public var keyCode: UInt32
    public var modifiers: UInt32
    public var keyString: String
    
    public static let defaultSearch = HotkeyConfig(keyCode: 49, modifiers: UInt32(optionKey), keyString: "Space")
    
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
        static let defaultViewMode = "defaultViewMode"
        static let defaultPreviewTab = "defaultPreviewTab"
        static let cardLayout = "cardLayout"
        static let enableReadStatus = "enableReadStatus"
        static let aiBrainConfig = "aiBrainConfig"
        static let didCompleteBrainOnboarding = "didCompleteBrainOnboarding"
        static let searchHotkey = "searchHotkey"
    }

    // MARK: - General Settings

    public var appLanguage: String {
        didSet { defaults.set(appLanguage, forKey: Keys.appLanguage) }
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

    public var defaultViewMode: String {
        didSet { defaults.set(defaultViewMode, forKey: Keys.defaultViewMode) }
    }

    /// Which preview tab a bookmark opens to (raw value of PreviewTab).
    public var defaultPreviewTab: String {
        didSet { defaults.set(defaultPreviewTab, forKey: Keys.defaultPreviewTab) }
    }

    /// Grid card layout: "titleFirst" (title on top, URL below) or "urlFirst".
    public var cardLayout: String {
        didSet { defaults.set(cardLayout, forKey: Keys.cardLayout) }
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
            // Trigger dynamic re-registration
            GlobalHotkey.shared.register(config: searchHotkey)
        }
    }

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

    public var resolvedLocale: Locale {
        switch appLanguage {
        case "en": return Locale(identifier: "en")
        case "de": return Locale(identifier: "de")
        default:   return .current
        }
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
        defaultViewMode = d.string(forKey: Keys.defaultViewMode) ?? "grid"
        defaultPreviewTab = d.string(forKey: Keys.defaultPreviewTab) ?? "Info"
        cardLayout = d.string(forKey: Keys.cardLayout) ?? "titleFirst"
        didCompleteBrainOnboarding = d.bool(forKey: Keys.didCompleteBrainOnboarding)
        if let data = d.data(forKey: Keys.searchHotkey),
           let config = try? JSONDecoder().decode(HotkeyConfig.self, from: data) {
            searchHotkey = config
        } else {
            searchHotkey = .defaultSearch
        }
        if let data = d.data(forKey: Keys.aiBrainConfig),
           let config = try? JSONDecoder().decode(AIBrainConfig.self, from: data) {
            aiBrainConfig = config
        } else {
            aiBrainConfig = AIBrainConfig()
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
                print("Failed to sync AI Brain config: \(error)")
            }
        }
    }
}
