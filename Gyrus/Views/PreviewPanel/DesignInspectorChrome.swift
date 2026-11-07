import SwiftUI

/// The six areas of the Design tab, in the order a review usually runs: get the
/// gist, lift the styles, look at the parts, check the breakpoints, fix what is
/// broken, then look at the site around the page.
enum DesignInspectorSection: String, CaseIterable, Identifiable {
    case overview
    case styles
    case components
    case responsive
    case audit
    case website

    var id: String { rawValue }

    /// The section stored under `designInspectorSection`. Older builds wrote
    /// `preview`, `system` or `issues` there; those no longer exist, and
    /// landing on the overview is the least surprising place to come back to.
    init(storedValue: String) {
        self = Self(rawValue: storedValue) ?? .overview
    }

    var title: LocalizedStringKey {
        switch self {
        case .overview: "Overview"
        case .styles: "Styles"
        case .components: "Components"
        case .responsive: "Responsive"
        case .audit: "Audit"
        case .website: "Website"
        }
    }

    var icon: String {
        switch self {
        case .overview: "macwindow.on.rectangle"
        case .styles: "paintpalette"
        case .components: "square.stack.3d.up"
        case .responsive: "laptopcomputer.and.iphone"
        case .audit: "checklist"
        case .website: "globe"
        }
    }
}

/// A segmented row that degrades with the inspector's width.
///
/// Six labelled segments need roughly 500 pt, while the inspector is usually
/// 320–420 pt wide. Shrinking the text until it fits made every label
/// unreadable, so the row drops labels instead: first from the unselected
/// segments, then from all of them. Every segment keeps its tooltip and
/// VoiceOver label, so nothing becomes anonymous.
struct DesignSectionPicker: View {
    @Binding var selection: DesignInspectorSection

    private enum LabelMode {
        case all
        case selectedOnly
        case none
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            row(.all)
            row(.selectedOnly)
            row(.none)
        }
        .padding(3)
        .background(Color.secondary.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
    }

    private func row(_ mode: LabelMode) -> some View {
        HStack(spacing: 2) {
            ForEach(DesignInspectorSection.allCases) { section in
                segment(section, showsTitle: mode == .all || (mode == .selectedOnly && section == selection))
            }
        }
    }

    private func segment(_ section: DesignInspectorSection, showsTitle: Bool) -> some View {
        let isSelected = section == selection
        return Button {
            selection = section
        } label: {
            Group {
                if showsTitle {
                    Label(section.title, systemImage: section.icon)
                } else {
                    Image(systemName: section.icon)
                }
            }
            .font(.caption.weight(isSelected ? .semibold : .medium))
            .foregroundStyle(isSelected ? Color.accentColor : .secondary)
            .lineLimit(1)
            // The ideal width has to be the full label, or ViewThatFits would
            // accept a row whose titles are then truncated.
            .fixedSize()
            .frame(maxWidth: .infinity, minHeight: 26)
            .padding(.horizontal, 6)
            .background(
                isSelected ? Color.accentColor.opacity(0.14) : .clear,
                in: RoundedRectangle(cornerRadius: 6)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(Text(section.title))
        .accessibilityLabel(Text(section.title))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

func designViewportIcon(_ name: String) -> String {
    switch name {
    case "desktop": "desktopcomputer"
    case "tablet": "ipad"
    case "mobile": "iphone"
    default: "rectangle"
    }
}

/// One picker for every section that shows per-viewport data, so the choice
/// carries over when switching sections instead of each area keeping its own.
struct DesignViewportPicker: View {
    let viewports: [APIClient.VisualViewportDTO]
    @Binding var selectedName: String?

    private var selected: APIClient.VisualViewportDTO? {
        viewports.first { $0.name == selectedName } ?? viewports.first
    }

    var body: some View {
        if viewports.count > 1, let selected {
            Menu {
                ForEach(viewports, id: \.name) { viewport in
                    Button {
                        selectedName = viewport.name
                    } label: {
                        Label {
                            Text(verbatim: "\(viewport.name.capitalized)  \(viewport.width) × \(viewport.height)")
                        } icon: {
                            Image(systemName: selected.name == viewport.name ? "checkmark" : designViewportIcon(viewport.name))
                        }
                    }
                }
            } label: {
                Label {
                    HStack(spacing: 4) {
                        Text(LocalizedStringKey(selected.name.capitalized))
                        Text(verbatim: "\(selected.width) × \(selected.height)")
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: designViewportIcon(selected.name))
                }
                .font(.caption.weight(.semibold))
                .lineLimit(1)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Choose viewport")
            .accessibilityLabel(Text("Viewport"))
            .accessibilityValue(Text(verbatim: "\(selected.name.capitalized), \(selected.width) × \(selected.height)"))
        }
    }
}

/// When the snapshot was taken, and why parts of it may be missing.
///
/// A partial capture used to be indistinguishable from a clean one: the failed
/// viewports were simply absent and nothing said why.
struct DesignCaptureStatusBar: View {
    let snapshot: APIClient.VisualSnapshotDTO

    var body: some View {
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
                case "partial": badge("Partial capture", color: .orange)
                case "failed": badge("Capture failed", color: .red)
                default: EmptyView()
                }

                Spacer(minLength: 0)
            }

            ForEach(snapshot.errors ?? []) { failure in
                Text("\(failure.viewport?.capitalized ?? "Viewport"): \(failure.message ?? "")")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }
        }
    }

    private func badge(_ title: LocalizedStringKey, color: Color) -> some View {
        Text(title)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(color.opacity(0.15), in: Capsule())
    }
}

struct DesignOutdatedNotice: View {
    let missingViewportNames: [String]
    let isSchemaOutdated: Bool
    let isCapturing: Bool
    let onReinspect: () -> Void

    var body: some View {
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
            Button(action: onReinspect) {
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

struct DesignHistoricalNotice: View {
    let onReturn: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "clock.arrow.circlepath")
                .foregroundStyle(.secondary)
            Text("Viewing an earlier capture. Reinspecting replaces the current one, not this.")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Button(action: onReturn) {
                Text("Back to latest")
                    .font(.caption.weight(.medium))
            }
            .buttonStyle(.borderless)
        }
        .padding(10)
        .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }
}

/// The backend keeps the last few captures. Being able to step back to one is
/// what turns the Design tab into something you can watch a site with: when a
/// competitor changes their palette or their layout, the previous capture is
/// the only evidence of what it used to be.
struct DesignHistoryMenu: View {
    let runs: [APIClient.VisualSnapshotRunDTO]
    let viewingRunId: String?
    let isCapturing: Bool
    let onLatest: () -> Void
    let onSelect: (APIClient.VisualSnapshotRunDTO) -> Void

    var body: some View {
        if runs.count > 1 {
            Menu {
                Button(action: onLatest) {
                    Label("Latest capture", systemImage: "clock.arrow.circlepath")
                }
                .disabled(viewingRunId == nil)

                Divider()

                ForEach(runs) { run in
                    Button {
                        onSelect(run)
                    } label: {
                        if viewingRunId == run.runId {
                            Label(label(run), systemImage: "checkmark")
                        } else {
                            Text(verbatim: label(run))
                        }
                    }
                }
            } label: {
                Label("History", systemImage: "clock.arrow.circlepath")
                    .font(.caption.weight(.medium))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(isCapturing)
        }
    }

    private func label(_ run: APIClient.VisualSnapshotRunDTO) -> String {
        var parts: [String] = []
        if let raw = run.capturedAt, let date = snapshotCaptureDate(raw) {
            parts.append(date.formatted(date: .abbreviated, time: .shortened))
        } else {
            parts.append(run.runId)
        }
        if let viewports = run.viewportCount {
            parts.append(String(localized: "\(viewports) viewports"))
        }
        if let issues = run.issueCount, issues > 0 {
            parts.append(String(localized: "\(issues) issues"))
        }
        if run.status == "partial" || run.status == "failed" {
            parts.append(run.status ?? "")
        }
        return parts.joined(separator: "  ·  ")
    }
}
