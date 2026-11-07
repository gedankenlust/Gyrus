import SwiftUI

/// Mirrors SNAPSHOT_SCHEMA_VERSION in backend/services/visual_snapshot_service.py.
///
/// The backend has always stamped a version into every snapshot, but nothing
/// ever read it, so a capture taken before a new field existed simply rendered
/// as empty sections with no explanation. Raise both constants together whenever
/// the capture gains something the inspector depends on; the reinspect notice
/// then appears on its own.
private let expectedSnapshotSchemaVersion = 7

struct VisualSnapshotTabView: View {
    @Environment(BookmarkStore.self) private var bookmarkStore
    let bookmark: Bookmark

    @State private var snapshot: APIClient.VisualSnapshotDTO?
    @State private var selectedViewportName: String?
    /// The raw value, so a section name from an older build (or a typo in the
    /// defaults) falls back to the overview instead of failing to decode.
    @AppStorage("designInspectorSection") private var storedSection = DesignInspectorSection.overview.rawValue
    @State private var stylesArea: DesignStylesArea = .colors
    @State private var websiteArea: DesignWebsiteArea = .content
    @State private var isLoading = false
    @State private var isCapturing = false
    @State private var captureStatus: APIClient.VisualSnapshotJobStatus?
    @State private var loadError: String?
    @State private var runs: [APIClient.VisualSnapshotRunDTO] = []
    /// Non-nil while an earlier capture is on screen instead of the current one.
    @State private var viewingRunId: String?

    private var selectedSection: Binding<DesignInspectorSection> {
        Binding(
            get: { DesignInspectorSection(storedValue: storedSection) },
            set: { storedSection = $0.rawValue }
        )
    }

    private var selectedViewport: APIClient.VisualViewportDTO? {
        guard let snapshot else { return nil }
        if let selectedViewportName,
           let viewport = snapshot.viewports.first(where: { $0.name == selectedViewportName }) {
            return viewport
        }
        return snapshot.viewports.first
    }

    private var missingViewportNames: [String] {
        guard let snapshot else { return [] }
        let captured = Set(snapshot.viewports.map(\.name))
        return ["desktop", "tablet", "mobile"].filter { !captured.contains($0) }
    }

    /// Snapshots predating the version stamp report nil and are treated as v1.
    private var isSchemaOutdated: Bool {
        guard let snapshot else { return false }
        return (snapshot.schemaVersion ?? 1) < expectedSnapshotSchemaVersion
    }

    private var needsReinspection: Bool {
        !missingViewportNames.isEmpty || isSchemaOutdated
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            if isLoading && snapshot == nil {
                loadingState("Loading snapshot...")
            } else if let loadError, snapshot == nil {
                errorState(loadError)
            } else if let snapshot {
                snapshotContent(snapshot)
            } else {
                emptyState
            }
        }
        .task(id: bookmark.id) {
            viewingRunId = nil
            await loadSnapshot()
            await loadRuns()
            await resumeSnapshotJobIfNeeded()
        }
    }

    private var header: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Spacer()
                if isCapturing {
                    ProgressView().scaleEffect(0.55)
                    Text(captureProgressLabel)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Button {
                        Task { await cancelSnapshotJob() }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.borderless)
                    .help("Cancel inspection")
                }

                if let snapshot {
                    Button {
                        copy(DesignSnapshotReport.markdown(snapshot: snapshot))
                        AppStore.shared.uiStateStore.showInfo(
                            AppSettings.shared.localized("Design report copied.")
                        )
                    } label: {
                        Label("Copy report", systemImage: "doc.on.doc")
                            .font(.caption.weight(.medium))
                    }
                    .buttonStyle(.borderless)
                    .disabled(isCapturing)
                    .help("Copy the complete design inspection as Markdown")
                }

                DesignHistoryMenu(
                    runs: runs,
                    viewingRunId: viewingRunId,
                    isCapturing: isCapturing,
                    onLatest: { Task { await returnToLatestSnapshot() } },
                    onSelect: { run in Task { await loadRun(run) } }
                )

                Button {
                    Task { await captureSnapshot() }
                } label: {
                    Label(snapshot == nil ? "Inspect" : "Reinspect", systemImage: "camera.metering.center.weighted")
                        .font(.caption.weight(.medium))
                }
                .buttonStyle(.borderless)
                .disabled(isCapturing)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.bar)
            Divider()
        }
    }

    private func snapshotContent(_ snapshot: APIClient.VisualSnapshotDTO) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            DesignCaptureStatusBar(snapshot: snapshot)
            if viewingRunId != nil {
                DesignHistoricalNotice { Task { await returnToLatestSnapshot() } }
            } else if needsReinspection {
                // A stored run is a record of the past, so nagging to reinspect
                // it would be nonsense; the notice belongs to the current capture.
                DesignOutdatedNotice(
                    missingViewportNames: missingViewportNames,
                    isSchemaOutdated: isSchemaOutdated,
                    isCapturing: isCapturing,
                    onReinspect: { Task { await captureSnapshot() } }
                )
            }

            DesignSectionPicker(selection: selectedSection)
            DesignViewportPicker(viewports: snapshot.viewports, selectedName: $selectedViewportName)

            if let viewport = selectedViewport {
                sectionContent(snapshot, viewport: viewport)
            } else {
                Text("No viewports captured yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// The browsers bring their own scroll view so their filter rows stay put;
    /// the other sections scroll as a whole.
    @ViewBuilder
    private func sectionContent(
        _ snapshot: APIClient.VisualSnapshotDTO,
        viewport: APIClient.VisualViewportDTO
    ) -> some View {
        // Rebuilding a browser per viewport and capture resets its filters and
        // paging, which would otherwise point into data that no longer exists.
        let identity = "\(bookmark.id)-\(viewport.name)-\(snapshot.capturedAt)"
        switch selectedSection.wrappedValue {
        case .overview:
            ScrollView {
                DesignOverviewView(
                    snapshot: snapshot,
                    viewport: viewport,
                    fallbackTitle: bookmark.title,
                    onNavigate: navigate
                )
                .padding(.bottom, 16)
            }
        case .styles:
            DesignSystemBrowser(viewport: viewport, pageURL: snapshot.url, area: $stylesArea)
                .id("styles-\(identity)")
        case .components:
            DesignComponentsBrowser(viewport: viewport)
                .id("components-\(identity)")
        case .responsive:
            ScrollView {
                DesignResponsiveView(viewports: snapshot.viewports, selectedName: $selectedViewportName)
                    .padding(.bottom, 16)
            }
        case .audit:
            ScrollView {
                DesignAuditView(viewport: viewport)
                    .padding(.bottom, 16)
            }
            .id("audit-\(identity)")
        case .website:
            DesignWebsiteBrowser(
                viewport: viewport,
                structure: snapshot.siteStructure,
                navigation: snapshot.navigation ?? [],
                area: $websiteArea
            )
            .id("website-\(identity)")
        }
    }

    private func navigate(_ target: DesignOverviewTarget) {
        switch target {
        case .audit:
            selectedSection.wrappedValue = .audit
        case .colors:
            stylesArea = .colors
            selectedSection.wrappedValue = .styles
        case .typography:
            stylesArea = .type
            selectedSection.wrappedValue = .styles
        case .technologies:
            websiteArea = .stack
            selectedSection.wrappedValue = .website
        }
    }

    private func loadRuns() async {
        runs = (try? await APIClient.shared.visualSnapshotRuns(bookmarkId: bookmark.id)) ?? []
    }

    private func loadRun(_ run: APIClient.VisualSnapshotRunDTO) async {
        do {
            let loaded = try await APIClient.shared.visualSnapshotRun(bookmarkId: bookmark.id, runId: run.runId)
            snapshot = loaded
            viewingRunId = run.runId
            selectedViewportName = loaded.viewports.first?.name
        } catch {
            AppStore.shared.uiStateStore.showError(designErrorMessage(error))
        }
    }

    private func returnToLatestSnapshot() async {
        viewingRunId = nil
        await loadSnapshot()
    }

    private func loadingState(_ text: LocalizedStringKey) -> some View {
        HStack(spacing: 8) {
            ProgressView().scaleEffect(0.6)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(16)
    }

    private var emptyState: some View {
        VStack(spacing: 18) {
            Spacer()
            Image(systemName: "camera.viewfinder")
                .font(.system(size: 42))
                .foregroundStyle(.secondary.opacity(0.55))
            VStack(spacing: 6) {
                Text("No design inspection yet")
                    .font(.headline)
                Text("Inspect the rendered page to collect visual, CSS, typography, structure and component evidence.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
            }
            Button {
                Task { await captureSnapshot() }
            } label: {
                Label("Inspect Page", systemImage: "camera.metering.center.weighted")
            }
            .buttonStyle(.borderedProminent)
            .disabled(isCapturing)
            Spacer()
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var captureProgressLabel: String {
        guard let status = captureStatus else { return String(localized: "Starting...") }
        let completed = status.completed ?? 0
        let total = max(status.total ?? 4, 1)
        switch status.stage {
        case "desktop": return String(localized: "Inspecting desktop...") + " \(completed + 1)/\(total)"
        case "tablet": return String(localized: "Inspecting tablet...") + " \(completed + 1)/\(total)"
        case "mobile": return String(localized: "Inspecting mobile...") + " \(completed + 1)/\(total)"
        case "site_structure": return String(localized: "Mapping website structure...") + " \(completed + 1)/\(total)"
        case "cancelling": return String(localized: "Cancelling...")
        default: return String(localized: "Starting design inspection...")
        }
    }

    private func errorState(_ message: String) -> some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 34))
                .foregroundStyle(.orange)
            Text("Design inspection unavailable")
                .font(.headline)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            Button("Try Again") {
                Task { await loadSnapshot() }
            }
            .buttonStyle(.borderedProminent)
            Spacer()
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func loadSnapshot() async {
        isLoading = true
        loadError = nil
        defer { isLoading = false }
        do {
            let loaded = try await APIClient.shared.visualSnapshot(bookmarkId: bookmark.id)
            snapshot = loaded
            selectedViewportName = loaded.viewports.first?.name
            updateBookmarkSnapshotStatus(loaded)
        } catch APIError.serverMessage(let message) where message == "Visual snapshot not found" {
            snapshot = nil
        } catch APIError.serverError(404) {
            snapshot = nil
        } catch {
            loadError = designErrorMessage(error)
        }
    }

    private func captureSnapshot() async {
        isCapturing = true
        defer { isCapturing = false }
        do {
            let status = try await APIClient.shared.startVisualSnapshotJob(bookmarkId: bookmark.id)
            try await pollSnapshotJob(from: status)
        } catch {
            AppStore.shared.uiStateStore.showError(error.localizedDescription)
        }
    }

    private func resumeSnapshotJobIfNeeded() async {
        guard !isCapturing else { return }
        guard let status = try? await APIClient.shared.visualSnapshotJobStatus(bookmarkId: bookmark.id),
              status.running else { return }
        isCapturing = true
        defer { isCapturing = false }
        do {
            try await pollSnapshotJob(from: status)
        } catch {
            AppStore.shared.uiStateStore.showError(error.localizedDescription)
        }
    }

    private func pollSnapshotJob(from initialStatus: APIClient.VisualSnapshotJobStatus) async throws {
        var status = initialStatus
        var consecutiveFailures = 0
        captureStatus = status
        while status.running && !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 450_000_000)
            guard !Task.isCancelled else { return }
            do {
                status = try await APIClient.shared.visualSnapshotJobStatus(bookmarkId: bookmark.id)
                captureStatus = status
                consecutiveFailures = 0
            } catch {
                consecutiveFailures += 1
                if consecutiveFailures >= 20 { throw error }
            }
        }

        if let error = status.error, !error.isEmpty {
            throw APIError.serverMessage(error)
        }
        guard let captured = status.snapshot else { return }
        snapshot = captured
        loadError = nil
        // A fresh capture always returns you to the present.
        viewingRunId = nil
        selectedViewportName = captured.viewports.first?.name
        updateBookmarkSnapshotStatus(captured)
        await loadRuns()
        AppStore.shared.uiStateStore.showInfo(String(localized: "Snapshot captured."))
    }

    private func cancelSnapshotJob() async {
        do {
            captureStatus = try await APIClient.shared.cancelVisualSnapshotJob(bookmarkId: bookmark.id)
        } catch {
            AppStore.shared.uiStateStore.showError(error.localizedDescription)
        }
    }

    private func designErrorMessage(_ error: Error) -> String {
        if case APIError.networkError = error {
            return String(localized: "The Gyrus backend could not be reached. Check the app status and try again.")
        }
        if case APIError.serverMessage(let message) = error,
           message.localizedCaseInsensitiveContains("playwright") ||
           message.localizedCaseInsensitiveContains("browser") ||
           message.localizedCaseInsensitiveContains("design engine") {
            return String(localized: "The design engine is not fully installed in this build of Gyrus.")
        }
        return error.localizedDescription
    }

    private func updateBookmarkSnapshotStatus(_ snapshot: APIClient.VisualSnapshotDTO) {
        let expected = [
            ("desktop", 1440, 900),
            ("tablet", 834, 1112),
            ("mobile", 390, 844),
        ]
        let complete = expected.allSatisfy { expectedViewport in
            snapshot.viewports.contains {
                $0.name == expectedViewport.0 &&
                $0.width == expectedViewport.1 &&
                $0.height == expectedViewport.2
            }
        }
        bookmarkStore.updateDesignSnapshotStatus(bookmarkId: bookmark.id, complete: complete)
    }
}
