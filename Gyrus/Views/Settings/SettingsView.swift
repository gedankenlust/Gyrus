import SwiftUI
import ServiceManagement

// MARK: - Root

struct SettingsView: View {
    @State private var settings = AppSettings.shared

    var body: some View {
        // Native macOS preferences look: tabs render as a top toolbar, each
        // pane sizes the window. No NavigationSplitView collapse button.
        TabView {
            GeneralPane()
                .tabItem { Label("General", systemImage: "gear") }
            AppearancePane()
                .tabItem { Label("Appearance", systemImage: "paintbrush") }
            AISettingsView()
                .tabItem { Label("AI Brain", systemImage: "brain.head.profile") }
            DataPane()
                .tabItem { Label("Data", systemImage: "externaldrive") }
            AboutPane()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 560, height: 480)
    }
}

// MARK: - General

private struct GeneralPane: View {
    @Bindable private var settings = AppSettings.shared

    @State private var launchAtLogin = (SMAppService.mainApp.status == .enabled)
    @State private var launchError: String? = nil
    @State private var showRelaunchPrompt = false

    var body: some View {
        Form {
            Section {
                Picker("Language", selection: $settings.appLanguage) {
                    Text("System Language").tag("system")
                    Text("English").tag("en")
                    Text("Deutsch").tag("de")
                }
                .onChange(of: settings.appLanguage) {
                    showRelaunchPrompt = true
                }

                Text("The language changes when Gyrus restarts.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } header: {
                Text("Localization")
            }
            .alert("Restart to Apply", isPresented: $showRelaunchPrompt) {
                Button("Restart Now") { AppSettings.relaunchApp() }
                Button("Later", role: .cancel) {}
            } message: {
                Text("The new language takes effect the next time Gyrus starts.")
            }

            Section("Behavior") {
                Toggle("Open automatically at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in
                        do {
                            if enabled {
                                try SMAppService.mainApp.register()
                            } else {
                                try SMAppService.mainApp.unregister()
                            }
                        } catch {
                            launchError = error.localizedDescription
                            launchAtLogin = !enabled
                        }
                    }
                Toggle("Confirm before deleting", isOn: $settings.confirmDelete)
                Toggle("Track read / unread", isOn: $settings.enableReadStatus)
                    .help("Show read/unread dots, the Unread view and the mark-as-read controls. Turn off for a plain bookmark list.")

                HStack {
                    Text("Global Search Shortcut")
                    Spacer()
                    // Setting the binding fires AppSettings.didSet, which
                    // re-registers the hotkey and updates the conflict flag.
                    HotkeyRecorder(hotkey: $settings.searchHotkey) { }
                }
                if settings.searchHotkeyConflict {
                    Text("This shortcut is already in use — pick another.")
                        .font(.caption).foregroundStyle(.red)
                }

                HStack {
                    Text("Quick Add Shortcut")
                    Spacer()
                    HotkeyRecorder(hotkey: $settings.quickAddHotkey) { }
                }
                .help("Open the quick-add panel from anywhere to save the URL in your clipboard.")
                if settings.quickAddHotkeyConflict {
                    Text("This shortcut is already in use — pick another.")
                        .font(.caption).foregroundStyle(.red)
                }

                Toggle("Show Gyrus in the menu bar", isOn: $settings.showMenuBarItem)
                    .help("A menu-bar icon for quick-adding bookmarks without opening the main window.")
            }

            Section("Export Defaults") {
                Picker("Format", selection: $settings.defaultExportFmt) {
                    Text("HTML (.html)").tag("html")
                    Text("CSV (.csv)").tag("csv")
                    Text("Markdown (.md)").tag("markdown")
                    Text("Plain Text (.txt)").tag("txt")
                }
            }
        }
        .formStyle(.grouped)
        .alert("Login Item Error", isPresented: Binding(
            get: { launchError != nil },
            set: { if !$0 { launchError = nil } }
        )) {
            Button("OK") { launchError = nil }
        } message: {
            if let error = launchError {
                Text(error)
            }
        }
    }
}

// MARK: - Appearance

private struct AppearancePane: View {
    @Bindable private var settings = AppSettings.shared

    var body: some View {
        Form {
            Section("Theme") {
                Picker("Appearance", selection: $settings.appTheme) {
                    Text("System").tag("system")
                    Text("Light").tag("light")
                    Text("Dark").tag("dark")
                }
                .pickerStyle(.segmented)
            }

            Section("Preview") {
                Picker("Open bookmarks on", selection: $settings.defaultPreviewTab) {
                    Text("Page").tag("Page")
                    Text("Design").tag("Design")
                    Text("AI Brain").tag("AI Brain")
                    Text("Notes").tag("Notes")
                }
                Text("Which tab a bookmark opens to. AI Brain only shows when the AI Brain is enabled.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Grid cards") {
                Picker("Show on top", selection: $settings.cardLayout) {
                    Text("Title").tag("titleFirst")
                    Text("Link").tag("urlFirst")
                }
                .pickerStyle(.segmented)
                Text("Whether each grid card leads with the page title or its link.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Data

private struct DataPane: View {
    @State private var store = AppStore.shared
    @State private var isExporting = false
    @State private var showConfirmReset = false
    @State private var resetType: AppStore.ResetType?
    @State private var pendingRestoreData: Data?
    @State private var restoreSummary: BackupPreview?
    @State private var restoreFilename = ""
    @State private var operationError: String?
    @State private var showConfirmRestore = false
    @State private var automaticBackup: APIClient.AutomaticBackupStatus?
    
    var body: some View {
        Form {
            if let operationError {
                Section { Label(operationError, systemImage: "exclamationmark.triangle").foregroundStyle(.red).textSelection(.enabled) }
            }
            Section("Backups") {
                if let date = automaticBackup?.lastBackupAt {
                    LabeledContent("Last automatic backup", value: date.formatted(date: .abbreviated, time: .shortened))
                } else {
                    Text("An automatic backup is created daily while Gyrus is running.").font(.caption).foregroundStyle(.secondary)
                }
                if let error = automaticBackup?.error {
                    Label(String(localized: "Automatic backup failed.") + " " + error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                }
                Button("Show safety backups in Finder") {
                    let root = ProcessInfo.processInfo.environment["GYRUS_DATA_DIR"].map { URL(fileURLWithPath: $0) }
                        ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".gyrus")
                    NSWorkspace.shared.open(root.appendingPathComponent("db/backups"))
                }

                HStack {
                    Button {
                        createBackup()
                    } label: {
                        Label("Create Backup...", systemImage: "arrow.down.doc")
                    }
                    .disabled(isExporting)

                    Button {
                        pickRestoreFile()
                    } label: {
                        Label("Restore from Backup…", systemImage: "arrow.up.doc")
                    }
                    .disabled(isExporting)
                }

                Text("Export all bookmarks, collections, and tags as a Gyrus backup file, or restore from one.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            
            Section("Maintenance") {
                let status = store.uiStateStore.metadataRefreshStatus
                let running = status?.running == true
                Button {
                    Task { await store.startMetadataRefresh() }
                } label: {
                    Label(running ? "Refreshing…" : "Refresh All Metadata",
                          systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(running)

                if running, let s = status {
                    ProgressView(value: Double(s.processed), total: Double(max(s.total, 1))) {
                        Text("Refreshing \(s.processed) of \(s.total)…")
                            .font(.caption)
                    }
                    Button(role: .cancel) {
                        Task { await store.cancelMetadataRefresh() }
                    } label: {
                        Label("Stop", systemImage: "stop.circle")
                    }
                }

                Text("Re-fetches favicons, descriptions and preview images for every bookmark. Use this to fix missing or outdated icons.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Cleanup") {
                HStack {
                    Button("Clear Image Cache") {
                        confirmReset(.cache)
                    }
                    Button("Reset AI Brain Files") {
                        confirmReset(.brain)
                    }
                }
            }

            Section {
                HStack {
                    Button("Clear All Bookmarks", role: .destructive) {
                        confirmReset(.bookmarks)
                    }
                    Button("Factory Reset Gyrus", role: .destructive) {
                        confirmReset(.factory)
                    }
                    .fontWeight(.bold)
                }
            } header: {
                Text("Danger Zone")
            } footer: {
                Text("Destructive actions cannot be undone. Please make sure you have a backup.")
            }
        }
        .formStyle(.grouped)
        .disabled(isExporting)
        .task { automaticBackup = try? await APIClient.shared.automaticBackupStatus() }
        .confirmationDialog(
            "Are you sure?",
            isPresented: $showConfirmReset,
            titleVisibility: .visible,
            presenting: resetType
        ) { type in
            Button(resetButtonTitle(for: type), role: .destructive) {
                Task {
                    do {
                        isExporting = true
                        operationError = nil
                        defer { isExporting = false }
                        try await store.handleReset(type: type)
                    } catch {
                        operationError = error.localizedDescription
                    }
                }
            }
            Button("Cancel", role: .cancel) { resetType = nil }
        } message: { type in
            Text(resetMessage(for: type))
        }
        .confirmationDialog(
            "Restore this backup?",
            isPresented: $showConfirmRestore,
            titleVisibility: .visible
        ) {
            Button("Replace All Data", role: .destructive) {
                if let data = pendingRestoreData { performRestore(data) }
                pendingRestoreData = nil
            }
            Button("Cancel", role: .cancel) { pendingRestoreData = nil }
        } message: {
            if let summary = restoreSummary {
                Text(restoreFilename)
                if let date = summary.exportedAt { Text(date.formatted(date: .abbreviated, time: .shortened)) }
                Text("\(summary.bookmarks) bookmarks, \(summary.collections) folders, \(summary.tags) tags, \(summary.notes) notes, \(summary.messages) chat messages.")
            }
            Text("This replaces your current library. A safety backup is created before replacement.")
        }
    }

    private func pickRestoreFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.title = "Choose Backup File"
        if panel.runModal() == .OK, let url = panel.url {
            isExporting = true
            operationError = nil
            Task {
                defer { isExporting = false }
                do {
                    let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                    guard size <= 100 * 1024 * 1024 else { throw APIError.serverMessage(String(localized: "Backup files are limited to 100 MB.")) }
                    let data = try await Task.detached { try Data(contentsOf: url) }.value
                    restoreSummary = try await APIClient.shared.previewBackup(data)
                    pendingRestoreData = data
                    restoreFilename = url.lastPathComponent
                    showConfirmRestore = true
                } catch {
                    operationError = String(localized: "This file could not be validated as a Gyrus backup.") + " " + error.localizedDescription
                }
            }
        }
    }

    private func performRestore(_ data: Data) {
        isExporting = true
        Task {
            defer { isExporting = false; store.finishLibraryReplacement() }
            do {
                await store.prepareForLibraryReplacement()
                try await APIClient.shared.restoreBackup(data)
                store.resetLocalLibraryState()
                await store.loadAll()
                store.uiStateStore.showInfo("Backup restored.")
            } catch {
                await store.loadAll()
                operationError = String(localized: "Restore failed: \(error.localizedDescription)")
            }
        }
    }

    private func confirmReset(_ type: AppStore.ResetType) {
        resetType = type
        showConfirmReset = true
    }
    
    private func resetButtonTitle(for type: AppStore.ResetType) -> String {
        switch type {
        case .cache: return String(localized: "Clear Cache")
        case .brain: return String(localized: "Reset Brain Files")
        case .bookmarks: return String(localized: "Clear All Bookmarks")
        case .factory: return String(localized: "Factory Reset")
        }
    }

    private func resetMessage(for type: AppStore.ResetType) -> String {
        switch type {
        case .cache:
            return String(localized: "This will delete all downloaded favicons and preview images. They will be re-downloaded when needed.")
        case .brain:
            return String(localized: "This will delete all AI-generated notes and summaries from your brain directory.")
        case .bookmarks:
            return String(localized: "This will permanently delete all bookmarks, collections, and tags. This action cannot be undone.")
        case .factory:
            return String(localized: "This resets your library and app preferences. The macOS login setting is kept. Language changes take effect after restarting Gyrus.")
        }
    }
    
    private func createBackup() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "GyrusBackup_\(Date().formatted(.iso8601.year().month().day())).json"
        panel.title = "Save Backup"
        
        if panel.runModal() == .OK, let url = panel.url {
            isExporting = true
            Task {
                defer { isExporting = false }
                do {
                    let data = try await APIClient.shared.downloadBackup()
                    try data.write(to: url, options: .atomic)
                } catch {
                    operationError = String(localized: "Backup failed: \(error.localizedDescription)")
                }
            }
        }
    }
}

// MARK: - About

private struct AboutPane: View {
    private var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.5.0"
    }
    private var build: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
    }
    private var releaseChannel: String? {
        guard let channel = Bundle.main.infoDictionary?["GyrusReleaseChannel"] as? String,
              !channel.isEmpty else {
            return nil
        }
        return channel
    }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 16) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 72, height: 72)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Gyrus")
                            .font(.title2.bold())
                        Text(
                            releaseChannel.map { "Version \(version) \($0) (\(build))" }
                                ?? "Version \(version) (\(build))"
                        )
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Text("Local-first bookmark manager for macOS")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 6)
            }

            Section {
                Link(destination: URL(string: "https://github.com/gedankenlust/Gyrus")!) {
                    Label {
                        Text("View Source on GitHub")
                    } icon: {
                        Image("GitHubMark")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 16, height: 16)
                    }
                }
                Link(destination: URL(string: "https://github.com/gedankenlust/Gyrus/issues")!) {
                    Label("Report an Issue", systemImage: "exclamationmark.bubble")
                }
                Link(destination: URL(string: "https://opensource.org/licenses/MIT")!) {
                    Label("MIT License", systemImage: "doc.text")
                }
            }
            
            Section("Acknowledgments") {
                Text("Built with SwiftUI, FastAPI, SQLAlchemy, BeautifulSoup4, and Readability-lxml.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
