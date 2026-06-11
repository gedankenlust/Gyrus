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
        .frame(width: 540, height: 430)
        .environment(\.locale, settings.resolvedLocale)
    }
}

// MARK: - General

private struct GeneralPane: View {
    @Bindable private var settings = AppSettings.shared

    @State private var launchAtLogin = (SMAppService.mainApp.status == .enabled)
    @State private var launchError: String? = nil

    var body: some View {
        Form {
            Section {
                Picker("Language", selection: $settings.appLanguage) {
                    Text("System Language").tag("system")
                    Text("English").tag("en")
                    Text("Deutsch").tag("de")
                }
                
                Text("Changes to menu bars and system dialogs require an app restart.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } header: {
                Text("Localization")
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
                    HotkeyRecorder(hotkey: $settings.searchHotkey) {
                        // Re-register hotkey immediately when changed
                        GlobalHotkey.shared.register(config: settings.searchHotkey)
                    }
                }
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
                    Text("Info").tag("Info")
                    Text("AI Brain").tag("AI Brain")
                    Text("Notes").tag("Notes")
                    Text("Web").tag("Web")
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
    @State private var pendingRestoreURL: URL?
    @State private var showConfirmRestore = false
    
    var body: some View {
        Form {
            Section("Backups") {
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
                Button("Clear Image Cache") {
                    confirmReset(.cache)
                }
                Button("Reset AI Brain Files") {
                    confirmReset(.brain)
                }
            }
            
            Section {
                Button("Clear All Bookmarks", role: .destructive) {
                    confirmReset(.bookmarks)
                }
                Button("Factory Reset Gyrus", role: .destructive) {
                    confirmReset(.factory)
                }
                .fontWeight(.bold)
            } header: {
                Text("Danger Zone")
            } footer: {
                Text("Destructive actions cannot be undone. Please make sure you have a backup.")
            }
        }
        .formStyle(.grouped)
        .confirmationDialog(
            "Are you sure?",
            isPresented: $showConfirmReset,
            titleVisibility: .visible,
            presenting: resetType
        ) { type in
            Button(resetButtonTitle(for: type), role: .destructive) {
                Task {
                    do {
                        try await store.handleReset(type: type)
                    } catch {
                        store.uiStateStore.showError(error.localizedDescription)
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
                if let url = pendingRestoreURL { performRestore(url) }
                pendingRestoreURL = nil
            }
            Button("Cancel", role: .cancel) { pendingRestoreURL = nil }
        } message: {
            Text("This replaces all current bookmarks, collections, and tags with the contents of the backup. This cannot be undone.")
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
            pendingRestoreURL = url
            showConfirmRestore = true
        }
    }

    private func performRestore(_ url: URL) {
        isExporting = true
        Task {
            defer { isExporting = false }
            do {
                let data = try Data(contentsOf: url)
                try await APIClient.shared.restoreBackup(data)
                await store.loadAll()
                store.uiStateStore.showInfo("Backup restored.")
            } catch {
                store.uiStateStore.showError("Restore failed: \(error.localizedDescription)")
            }
        }
    }

    private func confirmReset(_ type: AppStore.ResetType) {
        resetType = type
        showConfirmReset = true
    }
    
    private func resetButtonTitle(for type: AppStore.ResetType) -> String {
        switch type {
        case .cache: return "Clear Cache"
        case .brain: return "Reset Brain Files"
        case .bookmarks: return "Clear All Bookmarks"
        case .factory: return "Factory Reset"
        }
    }
    
    private func resetMessage(for type: AppStore.ResetType) -> String {
        switch type {
        case .cache:
            return "This will delete all downloaded favicons and preview images. They will be re-downloaded when needed."
        case .brain:
            return "This will delete all AI-generated notes and summaries from your brain directory."
        case .bookmarks:
            return "This will permanently delete all bookmarks, collections, and tags. This action cannot be undone."
        case .factory:
            return "This will wipe all data and reset Gyrus to its initial state. All settings and bookmarks will be lost."
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
                    try data.write(to: url)
                } catch {
                    store.uiStateStore.showError("Backup failed: \(error.localizedDescription)")
                }
            }
        }
    }
}

// MARK: - About

private struct AboutPane: View {
    private var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.7.0"
    }
    private var build: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
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
                        Text("Version \(version) (\(build))")
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
                    Label("View Source on GitHub", systemImage: "code.branch")
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
