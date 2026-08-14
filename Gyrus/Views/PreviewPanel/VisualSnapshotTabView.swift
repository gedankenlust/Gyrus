import SwiftUI
import AppKit
import WebKit
import UniformTypeIdentifiers

private let designSections = DesignInspectorSection.allCases

/// Mirrors SNAPSHOT_SCHEMA_VERSION in backend/services/visual_snapshot_service.py.
///
/// The backend has always stamped a version into every snapshot, but nothing
/// ever read it, so a capture taken before a new field existed simply rendered
/// as empty sections with no explanation. Raise both constants together whenever
/// the capture gains something the inspector depends on; the reinspect notice
/// then appears on its own.
private let expectedSnapshotSchemaVersion = 3

enum DesignInspectorSection: String, CaseIterable, Identifiable {
    case preview
    case issues
    case system
    case components
    case website

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .preview: "Preview"
        case .issues: "Issues"
        case .system: "System"
        case .components: "Components"
        case .website: "Website"
        }
    }

    var icon: String {
        switch self {
        case .preview: "macwindow.on.rectangle"
        case .issues: "exclamationmark.triangle"
        case .system: "paintpalette"
        case .components: "square.stack.3d.up"
        case .website: "globe"
        }
    }
}

private enum DesignReviewMode: String, CaseIterable, Identifiable {
    case snapshot = "Snapshot"
    case live = "Live"

    var id: String { rawValue }
}

struct VisualSnapshotTabView: View {
    @Environment(BookmarkStore.self) private var bookmarkStore
    let bookmark: Bookmark

    @State private var snapshot: APIClient.VisualSnapshotDTO?
    @State private var selectedViewportName: String?
    @State private var selectedSection: DesignInspectorSection = .preview
    @State private var reviewMode: DesignReviewMode = .snapshot
    @State private var isLoading = false
    @State private var isCapturing = false
    @State private var captureStatus: APIClient.VisualSnapshotJobStatus?
    @State private var isExportingPDF = false
    @State private var loadError: String?

    var selectedViewport: APIClient.VisualViewportDTO? {
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
            } else if snapshot == nil {
                emptyState
            } else {
                snapshotContent
            }
        }
        .task(id: bookmark.id) {
            await loadSnapshot()
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

    private func loadingState(_ text: String) -> some View {
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

    private var snapshotContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            captureStatusBar
            outdatedSnapshotNotice
            sectionPicker

            if let selectedViewport {
                if selectedSection == .preview {
                    reviewSection
                        .frame(maxHeight: .infinity, alignment: .top)
                } else {
                    ScrollView {
                        inspectorContent(selectedViewport)
                            .padding(.bottom, 16)
                    }
                }
            }
        }
        .padding(16)
    }

    @ViewBuilder
    private func inspectorContent(_ viewport: APIClient.VisualViewportDTO) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            switch selectedSection {
            case .preview:
                EmptyView()
            case .issues:
                compactViewportPicker
                issuesSection(viewport)
            case .system:
                compactViewportPicker
                styleSection(viewport)
            case .components:
                compactViewportPicker
                componentsSection(viewport)
            case .website:
                compactViewportPicker
                websiteSection(viewport)
            }
        }
    }

    private var captureProgressLabel: String {
        guard let status = captureStatus else { return String(localized: "Starting...") }
        let completed = status.completed ?? 0
        let total = max(status.total ?? 3, 1)
        switch status.stage {
        case "desktop": return String(localized: "Inspecting desktop...") + " \(completed + 1)/\(total)"
        case "tablet": return String(localized: "Inspecting tablet...") + " \(completed + 1)/\(total)"
        case "mobile": return String(localized: "Inspecting mobile...") + " \(completed + 1)/\(total)"
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

    /// A partial capture used to be indistinguishable from a clean one: the
    /// failed viewports were simply absent and nothing said why. Show when the
    /// snapshot was taken, and surface the per-viewport failure reasons.
    @ViewBuilder
    private var captureStatusBar: some View {
        if let snapshot {
            let failures = snapshot.errors ?? []
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    if let captured = snapshotCaptureDate(snapshot.capturedAt) {
                        Label {
                            Text(verbatim: captured.formatted(date: .abbreviated, time: .shortened))
                        } icon: {
                            Image(systemName: "clock")
                        }
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    }

                    switch snapshot.status {
                    case "partial":
                        captureBadge("Partial capture", color: .orange)
                    case "failed":
                        captureBadge("Capture failed", color: .red)
                    default:
                        EmptyView()
                    }

                    Spacer(minLength: 0)
                }

                ForEach(failures) { failure in
                    Text("\(failure.viewport?.capitalized ?? "Viewport"): \(failure.message ?? "")")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .textSelection(.enabled)
                }
            }
        }
    }

    private func captureBadge(_ title: LocalizedStringKey, color: Color) -> some View {
        Text(title)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(color.opacity(0.15), in: Capsule())
    }

    @ViewBuilder
    private var outdatedSnapshotNotice: some View {
        if needsReinspection {
            HStack(spacing: 10) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Snapshot needs reinspection")
                        .font(.caption.bold())
                    if !missingViewportNames.isEmpty {
                        Text("Missing: \(missingViewportNames.map(\.capitalized).joined(separator: ", "))")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    if isSchemaOutdated {
                        Text("Captured in an older inspection format. Some sections stay empty until you reinspect.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
                Button {
                    Task { await captureSnapshot() }
                } label: {
                    Label("Reinspect", systemImage: "camera.metering.center.weighted")
                        .font(.caption.weight(.medium))
                }
                .buttonStyle(.borderless)
                .disabled(isCapturing)
            }
            .padding(10)
            .background(Color.accentColor.opacity(0.14), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private var sectionPicker: some View {
        Picker("Section", selection: $selectedSection) {
            ForEach(designSections) { section in
                Text(section.title).tag(section)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }

    @ViewBuilder
    private var compactViewportPicker: some View {
        if let snapshot, snapshot.viewports.count > 1, let selectedViewport {
            HStack(spacing: 8) {
                Label("Viewport", systemImage: viewportIcon(selectedViewport.name))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                Menu {
                    ForEach(snapshot.viewports, id: \.name) { viewport in
                        Button {
                            selectedViewportName = viewport.name
                        } label: {
                            Label(
                                "\(viewport.name.capitalized) \(viewport.width)x\(viewport.height)",
                                systemImage: viewportIcon(viewport.name)
                            )
                        }
                    }
                } label: {
                    Text("\(selectedViewport.name.capitalized) \(selectedViewport.width)x\(selectedViewport.height)")
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color.secondary.opacity(0.14), in: RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(.plain)

                Spacer(minLength: 0)
            }
        }
    }

    private func viewportIcon(_ name: String) -> String {
        switch name {
        case "desktop":
            "desktopcomputer"
        case "tablet":
            "ipad"
        case "mobile":
            "iphone"
        default:
            "rectangle"
        }
    }

    private var reviewSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Picker("Mode", selection: $reviewMode) {
                    ForEach(DesignReviewMode.allCases) { mode in
                        Text(LocalizedStringKey(mode.rawValue)).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 180)

                Spacer(minLength: 0)

                Button {
                    guard let snapshot else { return }
                    Task { await exportViewportPDF(snapshot) }
                } label: {
                    if isExportingPDF {
                        ProgressView().scaleEffect(0.55)
                    } else {
                        Label("PDF", systemImage: "doc.richtext")
                            .font(.caption.weight(.medium))
                    }
                }
                .buttonStyle(.borderless)
                .disabled(snapshot?.viewports.isEmpty ?? true || isExportingPDF)
            }

            reviewViewportPicker

            if let snapshot, snapshot.viewports.isEmpty {
                Text("No viewports captured yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if let snapshot, let selectedViewport {
                switch reviewMode {
                case .snapshot:
                    SnapshotViewportFrame(viewport: selectedViewport)
                case .live:
                    LiveViewportFrame(url: URL(string: snapshot.url), viewport: selectedViewport)
                }
            }
        }
    }

    @ViewBuilder
    private var reviewViewportPicker: some View {
        if let snapshot, snapshot.viewports.count > 1 {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 6)], alignment: .leading, spacing: 6) {
                ForEach(snapshot.viewports, id: \.name) { viewport in
                    Button {
                        selectedViewportName = viewport.name
                    } label: {
                        VStack(spacing: 2) {
                            Image(systemName: viewportIcon(viewport.name))
                                .font(.caption2.weight(.semibold))
                            Text(viewport.name.capitalized)
                                .font(.caption.weight(.semibold))
                            Text("\(viewport.width)x\(viewport.height)")
                                .font(.caption2)
                                .foregroundStyle((selectedViewport?.name == viewport.name) ? .white.opacity(0.78) : .secondary)
                        }
                        .foregroundStyle((selectedViewport?.name == viewport.name) ? .white : .primary)
                        .frame(maxWidth: .infinity, minHeight: 42)
                        .background(
                            (selectedViewport?.name == viewport.name ? Color.accentColor : Color.secondary.opacity(0.16)),
                            in: RoundedRectangle(cornerRadius: 7)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    @MainActor
    private func exportViewportPDF(_ snapshot: APIClient.VisualSnapshotDTO) async {
        isExportingPDF = true
        defer { isExportingPDF = false }

        do {
            var pages: [(viewport: APIClient.VisualViewportDTO, image: NSImage)] = []
            for viewport in snapshot.viewports {
                let url = APIClient.shared.visualSnapshotFileURL(path: viewport.screenshotURL)
                let (data, _) = try await URLSession.shared.data(from: url)
                if let image = NSImage(data: data) {
                    pages.append((viewport, image))
                }
            }

            guard !pages.isEmpty else {
                AppStore.shared.uiStateStore.showError("No screenshots available for PDF export.")
                return
            }

            let panel = NSSavePanel()
            panel.allowedContentTypes = [.pdf]
            panel.nameFieldStringValue = "\(safeFilename(snapshot.title.isEmpty ? bookmark.title : snapshot.title))-viewports.pdf"
            panel.canCreateDirectories = true
            guard panel.runModal() == .OK, let outputURL = panel.url else { return }

            guard let data = viewportPDFData(snapshot: snapshot, pages: pages) else {
                AppStore.shared.uiStateStore.showError("Could not create PDF.")
                return
            }

            try data.write(to: outputURL)
            AppStore.shared.uiStateStore.showInfo("Viewport PDF exported.")
        } catch {
            AppStore.shared.uiStateStore.showError(error.localizedDescription)
        }
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
        selectedViewportName = captured.viewports.first?.name
        updateBookmarkSnapshotStatus(captured)
        AppStore.shared.uiStateStore.showInfo("Snapshot captured.")
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
