import SwiftUI
import AppKit
import WebKit
import UniformTypeIdentifiers

private let designMetricColumns = [GridItem(.adaptive(minimum: 96), spacing: 8)]
private let designSectionColumns = [GridItem(.adaptive(minimum: 92), spacing: 6)]
private let designViewportColumns = [GridItem(.adaptive(minimum: 148), spacing: 8)]
private let primaryDesignSections: [DesignInspectorSection] = [
    .review,
    .overview,
    .visual,
    .colors,
    .typography,
    .components,
    .layout,
]
private let advancedDesignSections: [DesignInspectorSection] = [
    .assets,
    .seo,
    .accessibility,
    .network,
    .console,
    .raw,
]

private enum DesignInspectorSection: String, CaseIterable, Identifiable {
    case review
    case overview
    case visual
    case colors
    case typography
    case components
    case layout
    case assets
    case seo
    case accessibility
    case network
    case console
    case raw

    var id: String { rawValue }

    var title: String {
        switch self {
        case .review: "Review"
        case .overview: "Overview"
        case .visual: "Visual"
        case .colors: "Colors"
        case .typography: "Type"
        case .components: "Components"
        case .layout: "Layout"
        case .assets: "Assets"
        case .seo: "SEO"
        case .accessibility: "A11y"
        case .network: "Network"
        case .console: "Console"
        case .raw: "Raw"
        }
    }

    var icon: String {
        switch self {
        case .review: "macwindow.on.rectangle"
        case .overview: "rectangle.grid.2x2"
        case .visual: "photo"
        case .colors: "eyedropper"
        case .typography: "textformat"
        case .components: "square.stack.3d.up"
        case .layout: "rectangle.3.group"
        case .assets: "photo.on.rectangle.angled"
        case .seo: "magnifyingglass"
        case .accessibility: "accessibility"
        case .network: "point.3.connected.trianglepath.dotted"
        case .console: "terminal"
        case .raw: "curlybraces.square"
        }
    }
}

private enum DesignReviewMode: String, CaseIterable, Identifiable {
    case snapshot = "Snapshot"
    case live = "Live"

    var id: String { rawValue }
}

struct VisualSnapshotTabView: View {
    let bookmark: Bookmark

    @State private var snapshot: APIClient.VisualSnapshotDTO?
    @State private var selectedViewportName: String?
    @State private var selectedSection: DesignInspectorSection = .review
    @State private var reviewMode: DesignReviewMode = .snapshot
    @State private var isLoading = false
    @State private var isCapturing = false
    @State private var isExportingPDF = false

    private var selectedViewport: APIClient.VisualViewportDTO? {
        guard let snapshot else { return nil }
        if let selectedViewportName,
           let viewport = snapshot.viewports.first(where: { $0.name == selectedViewportName }) {
            return viewport
        }
        return snapshot.viewports.first
    }

    private var colors: [SnapshotColor] {
        guard let viewport = selectedViewport else { return [] }
        return SnapshotColor.unique(from: viewport.dominantColors + viewport.observedColors)
    }

    private var missingViewportNames: [String] {
        guard let snapshot else { return [] }
        let captured = Set(snapshot.viewports.map(\.name))
        return ["desktop", "tablet", "mobile"].filter { !captured.contains($0) }
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            if isLoading && snapshot == nil {
                loadingState("Loading snapshot...")
            } else if snapshot == nil {
                emptyState
            } else {
                snapshotContent
            }
        }
        .task(id: bookmark.id) {
            await loadSnapshot()
        }
    }

    private var header: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Label("Design", systemImage: "viewfinder")
                    .font(.headline)
                Spacer()
                if isCapturing {
                    ProgressView().scaleEffect(0.55)
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
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                outdatedSnapshotNotice
                sectionPicker

                if let selectedViewport {
                    switch selectedSection {
                    case .review:
                        reviewSection
                    case .overview:
                        viewportPicker
                        overviewSection(selectedViewport)
                    case .visual:
                        viewportPicker
                        screenshotSection(selectedViewport)
                    case .colors:
                        viewportPicker
                        colorsSection
                    case .typography:
                        viewportPicker
                        typographySection(selectedViewport)
                    case .components:
                        viewportPicker
                        componentsSection(selectedViewport)
                    case .layout:
                        viewportPicker
                        layoutSection(selectedViewport)
                    case .assets:
                        viewportPicker
                        assetsSection(selectedViewport)
                    case .seo:
                        viewportPicker
                        seoSection(selectedViewport)
                    case .accessibility:
                        viewportPicker
                        accessibilitySection(selectedViewport)
                    case .network:
                        viewportPicker
                        networkSection(selectedViewport)
                    case .console:
                        viewportPicker
                        consoleSection(selectedViewport)
                    case .raw:
                        viewportPicker
                        elementSamplesSection(selectedViewport)
                    }
                }
            }
            .padding(16)
        }
    }

    @ViewBuilder
    private var outdatedSnapshotNotice: some View {
        if !missingViewportNames.isEmpty {
            HStack(spacing: 10) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Snapshot needs reinspection")
                        .font(.caption.bold())
                    Text("Missing: \(missingViewportNames.map(\.capitalized).joined(separator: ", "))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
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
        let advancedActive = advancedDesignSections.contains(selectedSection)

        return LazyVGrid(columns: designSectionColumns, alignment: .leading, spacing: 6) {
            ForEach(primaryDesignSections) { section in
                DesignSectionButton(
                    section: section,
                    isSelected: selectedSection == section
                ) {
                    selectedSection = section
                }
            }

            Menu {
                ForEach(advancedDesignSections) { section in
                    Button {
                        selectedSection = section
                    } label: {
                        Label(section.title, systemImage: section.icon)
                    }
                }
            } label: {
                Label(advancedActive ? selectedSection.title : "More", systemImage: advancedActive ? selectedSection.icon : "ellipsis.circle")
                    .labelStyle(.titleAndIcon)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(advancedActive ? .white : .primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .frame(maxWidth: .infinity, minHeight: 32)
                    .background(
                        advancedActive ? Color.accentColor : Color.secondary.opacity(0.14),
                        in: RoundedRectangle(cornerRadius: 7)
                    )
            }
            .buttonStyle(.plain)
            .menuStyle(.button)
        }
    }

    @ViewBuilder
    private var viewportPicker: some View {
        if let snapshot, snapshot.viewports.count > 1 {
            LazyVGrid(columns: designViewportColumns, alignment: .leading, spacing: 8) {
                ForEach(snapshot.viewports, id: \.name) { viewport in
                    Button {
                        selectedViewportName = viewport.name
                    } label: {
                        HStack(spacing: 7) {
                            Image(systemName: viewportIcon(viewport.name))
                                .font(.caption.weight(.semibold))
                            Text("\(viewport.name.capitalized) \(viewport.width)x\(viewport.height)")
                                .font(.caption.weight(.medium))
                                .lineLimit(1)
                                .minimumScaleFactor(0.85)
                        }
                        .foregroundStyle((selectedViewport?.name == viewport.name) ? .white : .primary)
                        .frame(maxWidth: .infinity, minHeight: 34, alignment: .center)
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
                        Text(mode.rawValue).tag(mode)
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

    private func screenshotSection(_ viewport: APIClient.VisualViewportDTO) -> some View {
        SnapshotSection(title: "Rendered Page", icon: "rectangle.dashed") {
            VStack(alignment: .leading, spacing: 8) {
                AsyncImage(url: APIClient.shared.visualSnapshotFileURL(path: viewport.screenshotURL)) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFit()
                    default:
                        Rectangle()
                            .fill(.quaternary)
                            .frame(height: 220)
                            .overlay {
                                Image(systemName: "photo")
                                    .foregroundStyle(.secondary)
                            }
                    }
                }
                .frame(maxHeight: 420)
                .clipShape(RoundedRectangle(cornerRadius: 8))

                if let pageTitle = viewport.pageTitle, !pageTitle.isEmpty {
                    Text(pageTitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
        }
    }

    private func overviewSection(_ viewport: APIClient.VisualViewportDTO) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            SnapshotSection(title: "Overview", icon: "rectangle.grid.2x2") {
                LazyVGrid(columns: designMetricColumns, spacing: 8) {
                    MetricPill(label: "Colors", value: colors.count)
                    MetricPill(label: "Fonts", value: viewport.observedFonts.count)
                    MetricPill(label: "Elements", value: viewport.elementSamples?.count ?? 0)
                    MetricPill(label: "CSS Vars", value: viewport.cssVariables?.count ?? 0)
                    MetricPill(label: "Requests", value: viewport.network?.requestCount ?? 0)
                    MetricPill(label: "Buttons", value: viewport.structure.buttons)
                    MetricPill(label: "Images", value: viewport.structure.images)
                    MetricPill(label: "SVG", value: viewport.structure.svgs)
                }

                if let metaDescription = viewport.metaDescription, !metaDescription.isEmpty {
                    Text(metaDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(4)
                        .textSelection(.enabled)
                }
            }

            screenshotSection(viewport)
            colorsSection
            typographySection(viewport)
            structureSection(viewport)
        }
    }

    private var colorsSection: some View {
        SnapshotSection(title: "Colors", icon: "eyedropper") {
            VStack(alignment: .leading, spacing: 12) {
                if colors.isEmpty {
                    Text("No colors captured.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 118), spacing: 8)], spacing: 8) {
                        ForEach(colors) { color in
                            SnapshotColorChip(color: color)
                        }
                    }
                }

                if let variables = selectedViewport?.cssVariables, !variables.isEmpty {
                    InspectorList(title: "CSS Variables", values: variables.prefix(80).map { "\($0.name): \($0.value)" })
                }
            }
        }
    }

    private func typographySection(_ viewport: APIClient.VisualViewportDTO) -> some View {
        SnapshotSection(title: "Typography", icon: "textformat") {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(viewport.observedFonts.enumerated()), id: \.offset) { _, font in
                    CopyRow(value: font, systemImage: "doc.on.doc")
                }
            }
        }
    }

    private func structureSection(_ viewport: APIClient.VisualViewportDTO) -> some View {
        SnapshotSection(title: "Structure", icon: "list.bullet.rectangle") {
            VStack(alignment: .leading, spacing: 10) {
                LazyVGrid(columns: designMetricColumns, spacing: 8) {
                    MetricPill(label: "Links", value: viewport.structure.links)
                    MetricPill(label: "Buttons", value: viewport.structure.buttons)
                    MetricPill(label: "Images", value: viewport.structure.images)
                    MetricPill(label: "SVG", value: viewport.structure.svgs)
                    MetricPill(label: "Forms", value: viewport.structure.forms)
                }

                ForEach(viewport.structure.h1, id: \.self) { heading in
                    CopyRow(value: "H1: \(heading)", systemImage: "h.square")
                }

                ForEach(viewport.structure.h2.prefix(8), id: \.self) { heading in
                    CopyRow(value: "H2: \(heading)", systemImage: "h.square")
                }
            }
        }
    }

    private func elementSamplesSection(_ viewport: APIClient.VisualViewportDTO) -> some View {
        SnapshotSection(title: "Computed Elements", icon: "curlybraces.square") {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array((viewport.elementSamples ?? []).prefix(80))) { sample in
                    ElementSampleRow(sample: sample)
                }
            }
        }
    }

    private func componentsSection(_ viewport: APIClient.VisualViewportDTO) -> some View {
        let samples = viewport.elementSamples ?? []
        let groups = [
            ComponentGroup(title: "Navigation", icon: "point.3.connected.trianglepath.dotted", samples: samples.matching(["nav", "header", "menu"])),
            ComponentGroup(title: "Hero / Sections", icon: "rectangle.topthird.inset.filled", samples: samples.matching(["hero", "section", "main", "article"])),
            ComponentGroup(title: "CTA / Buttons", icon: "button.programmable", samples: samples.filter { $0.tag == "button" || $0.selectorHint.localizedCaseInsensitiveContains("btn") || $0.selectorHint.localizedCaseInsensitiveContains("cta") }),
            ComponentGroup(title: "Cards", icon: "rectangle.stack", samples: samples.matching(["card", "tile", "item"])),
            ComponentGroup(title: "Forms", icon: "rectangle.and.pencil.and.ellipsis", samples: samples.filter { ["form", "input", "textarea", "select", "label"].contains($0.tag) }),
        ]

        return SnapshotSection(title: "Components", icon: "square.stack.3d.up") {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(groups.filter { !$0.samples.isEmpty }) { group in
                    ComponentGroupView(group: group)
                }

                if groups.allSatisfy({ $0.samples.isEmpty }) {
                    Text("No obvious component patterns found yet. Raw computed elements are still available in Raw.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func layoutSection(_ viewport: APIClient.VisualViewportDTO) -> some View {
        let samples = viewport.elementSamples ?? []
        let maxWidth = samples.map(\.width).max() ?? 0
        let commonRadii = frequency(samples.map(\.borderRadius).filter { !$0.isEmpty && $0 != "0px" })
        let commonPadding = frequency(samples.map(\.padding).filter { !$0.isEmpty })
        let commonDisplay = frequency(samples.map(\.display).filter { !$0.isEmpty })

        return SnapshotSection(title: "Layout", icon: "rectangle.3.group") {
            VStack(alignment: .leading, spacing: 10) {
                LazyVGrid(columns: designMetricColumns, spacing: 8) {
                    MetricPill(label: "Viewport W", value: viewport.width)
                    MetricPill(label: "Viewport H", value: viewport.height)
                    MetricPill(label: "Max Element W", value: maxWidth)
                }

                InspectorList(title: "Display Patterns", values: commonDisplay)
                InspectorList(title: "Padding Patterns", values: commonPadding)
                InspectorList(title: "Radius Patterns", values: commonRadii)
            }
        }
    }

    private func assetsSection(_ viewport: APIClient.VisualViewportDTO) -> some View {
        SnapshotSection(title: "Assets", icon: "photo.on.rectangle.angled") {
            VStack(alignment: .leading, spacing: 10) {
                LazyVGrid(columns: designMetricColumns, spacing: 8) {
                    MetricPill(label: "Images", value: viewport.assets?.images?.count ?? viewport.structure.images)
                    MetricPill(label: "Icons", value: viewport.assets?.icons?.count ?? 0)
                    MetricPill(label: "CSS", value: viewport.assets?.stylesheets?.count ?? 0)
                    MetricPill(label: "Scripts", value: viewport.assets?.scripts?.count ?? 0)
                }

                AssetList(title: "Images", assets: viewport.assets?.images ?? [])
                AssetList(title: "Icons", assets: viewport.assets?.icons ?? [])
                AssetList(title: "Stylesheets", assets: viewport.assets?.stylesheets ?? [])
                AssetList(title: "Scripts", assets: viewport.assets?.scripts ?? [])
            }
        }
    }

    private func seoSection(_ viewport: APIClient.VisualViewportDTO) -> some View {
        SnapshotSection(title: "SEO / Content", icon: "magnifyingglass") {
            VStack(alignment: .leading, spacing: 8) {
                if let title = viewport.seo?.title ?? viewport.pageTitle, !title.isEmpty {
                    CopyRow(value: "Title: \(title)", systemImage: "textformat.size")
                }
                if let metaDescription = viewport.seo?.metaDescription ?? viewport.metaDescription, !metaDescription.isEmpty {
                    CopyRow(value: "Description: \(metaDescription)", systemImage: "text.quote")
                }
                if let canonical = viewport.seo?.canonical, !canonical.isEmpty {
                    CopyRow(value: "Canonical: \(canonical)", systemImage: "link")
                }
                if let language = viewport.seo?.language, !language.isEmpty {
                    CopyRow(value: "Language: \(language)", systemImage: "globe")
                }
                if let robots = viewport.seo?.robots, !robots.isEmpty {
                    CopyRow(value: "Robots: \(robots)", systemImage: "gearshape")
                }
                LazyVGrid(columns: designMetricColumns, spacing: 8) {
                    MetricPill(label: "Internal", value: viewport.seo?.internalLinks ?? 0)
                    MetricPill(label: "External", value: viewport.seo?.externalLinks ?? 0)
                    MetricPill(label: "JSON-LD", value: viewport.seo?.jsonLd?.count ?? 0)
                    MetricPill(label: "OG", value: viewport.seo?.openGraph?.count ?? 0)
                    MetricPill(label: "Twitter", value: viewport.seo?.twitter?.count ?? 0)
                }

                structureSection(viewport)
                MetaList(title: "Open Graph", items: viewport.seo?.openGraph ?? [])
                MetaList(title: "Twitter Cards", items: viewport.seo?.twitter ?? [])
                InspectorList(title: "JSON-LD", values: (viewport.seo?.jsonLd ?? []).prefix(8).map { $0 })
            }
        }
    }

    private func accessibilitySection(_ viewport: APIClient.VisualViewportDTO) -> some View {
        SnapshotSection(title: "Accessibility", icon: "accessibility") {
            VStack(alignment: .leading, spacing: 10) {
                LazyVGrid(columns: designMetricColumns, spacing: 8) {
                    MetricPill(label: "Missing Alt", value: viewport.accessibility?.missingAltImages?.count ?? 0)
                    MetricPill(label: "Empty Buttons", value: viewport.accessibility?.emptyButtons?.count ?? 0)
                    MetricPill(label: "Unlabeled Inputs", value: viewport.accessibility?.unlabeledInputs?.count ?? 0)
                    MetricPill(label: "Heading Skips", value: viewport.accessibility?.headingSkips?.count ?? 0)
                }

                AssetList(title: "Images Missing Alt", assets: viewport.accessibility?.missingAltImages ?? [])
                A11yItemList(title: "Buttons Without Accessible Text", items: viewport.accessibility?.emptyButtons ?? [])
                A11yItemList(title: "Inputs Without Labels", items: viewport.accessibility?.unlabeledInputs ?? [])
                HeadingSkipList(skips: viewport.accessibility?.headingSkips ?? [])
            }
        }
    }

    private func networkSection(_ viewport: APIClient.VisualViewportDTO) -> some View {
        SnapshotSection(title: "Network", icon: "point.3.connected.trianglepath.dotted") {
            VStack(alignment: .leading, spacing: 10) {
                LazyVGrid(columns: designMetricColumns, spacing: 8) {
                    MetricPill(label: "Requests", value: viewport.network?.requestCount ?? 0)
                    MetricPill(label: "Failed", value: viewport.network?.failedRequests?.count ?? 0)
                    MetricPill(label: "Large", value: viewport.network?.largeRequests?.count ?? 0)
                }
                if let counts = viewport.network?.resourceCounts, !counts.isEmpty {
                    InspectorList(title: "Resource Types", values: counts.map { "\($0.type): \($0.count)" })
                }
                NetworkRequestList(title: "Failed Requests", requests: viewport.network?.failedRequests ?? [])
                NetworkRequestList(title: "Large Requests", requests: viewport.network?.largeRequests ?? [])
            }
        }
    }

    private func consoleSection(_ viewport: APIClient.VisualViewportDTO) -> some View {
        SnapshotSection(title: "Console", icon: "terminal") {
            let messages = viewport.consoleMessages ?? []
            VStack(alignment: .leading, spacing: 8) {
                if messages.isEmpty {
                    Text("No console messages captured.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(messages.prefix(80)) { message in
                        CopyRow(value: "[\(message.type ?? "log")] \(message.text ?? "")", systemImage: "terminal")
                    }
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
        defer { isLoading = false }
        do {
            let loaded = try await APIClient.shared.visualSnapshot(bookmarkId: bookmark.id)
            snapshot = loaded
            selectedViewportName = loaded.viewports.first?.name
        } catch APIError.serverMessage(let message) where message == "Visual snapshot not found" {
            snapshot = nil
        } catch APIError.serverError(404) {
            snapshot = nil
        } catch {
            snapshot = nil
        }
    }

    private func captureSnapshot() async {
        isCapturing = true
        defer { isCapturing = false }
        do {
            let captured = try await APIClient.shared.createVisualSnapshot(bookmarkId: bookmark.id)
            snapshot = captured
            selectedViewportName = captured.viewports.first?.name
            AppStore.shared.uiStateStore.showInfo("Snapshot captured.")
        } catch {
            AppStore.shared.uiStateStore.showError(error.localizedDescription)
        }
    }
}

private struct DesignSectionButton: View {
    let section: DesignInspectorSection
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(section.title, systemImage: section.icon)
                .labelStyle(.titleAndIcon)
                .font(.caption.weight(.semibold))
                .foregroundStyle(isSelected ? .white : .primary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity, minHeight: 32, alignment: .center)
                .background(
                    isSelected ? Color.accentColor : Color.secondary.opacity(0.14),
                    in: RoundedRectangle(cornerRadius: 7)
                )
        }
        .buttonStyle(.plain)
        .help(section.title)
    }
}

private struct SnapshotSection<Content: View>: View {
    let title: String
    let icon: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: icon)
                .font(.caption.bold())
                .foregroundStyle(.secondary)
            content
        }
    }
}

private struct SnapshotViewportFrame: View {
    let viewport: APIClient.VisualViewportDTO

    private var previewSize: CGSize {
        reviewPreviewSize(for: viewport)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ViewportFrameHeader(viewport: viewport, trailing: "Snapshot")

            ViewportScreenshotImage(viewport: viewport)
                .frame(width: previewSize.width, height: previewSize.height)
                .background(.white)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(.secondary.opacity(0.25), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

private struct LiveViewportFrame: View {
    let url: URL?
    let viewport: APIClient.VisualViewportDTO

    private var previewSize: CGSize {
        reviewPreviewSize(for: viewport)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ViewportFrameHeader(viewport: viewport, trailing: "Live")

            if let url {
                let scale = reviewPreviewScale(for: viewport)
                LiveViewportWebView(url: url, viewport: viewport)
                    .frame(width: CGFloat(viewport.width), height: CGFloat(viewport.height))
                    .scaleEffect(scale, anchor: .topLeading)
                    .frame(width: previewSize.width, height: previewSize.height, alignment: .topLeading)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(.secondary.opacity(0.25), lineWidth: 1)
                    )
                    .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
            } else {
                Text("Invalid URL.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

private struct ViewportScreenshotImage: View {
    let viewport: APIClient.VisualViewportDTO

    @State private var image: NSImage?
    @State private var isLoading = false

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Rectangle()
                    .fill(.quaternary)
                    .overlay {
                        if isLoading {
                            ProgressView().scaleEffect(0.6)
                        } else {
                            Image(systemName: "photo")
                                .foregroundStyle(.secondary)
                        }
                    }
            }
        }
        .clipped()
        .task(id: viewport.screenshotURL) {
            await loadImage()
        }
    }

    private func loadImage() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        do {
            let url = APIClient.shared.visualSnapshotFileURL(path: viewport.screenshotURL)
            let (data, _) = try await URLSession.shared.data(from: url)
            guard let source = NSImage(data: data) else { return }
            image = cropViewport(from: source, viewport: viewport) ?? source
        } catch {
            image = nil
        }
    }

    private func cropViewport(from source: NSImage, viewport: APIClient.VisualViewportDTO) -> NSImage? {
        guard let cgImage = source.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let scale = CGFloat(cgImage.width) / CGFloat(max(viewport.width, 1))
        let cropHeight = min(cgImage.height, Int((CGFloat(viewport.height) * scale).rounded()))
        guard cropHeight > 0 else { return nil }
        let cropRect = CGRect(x: 0, y: 0, width: cgImage.width, height: cropHeight)
        guard let cropped = cgImage.cropping(to: cropRect) else { return nil }
        return NSImage(
            cgImage: cropped,
            size: NSSize(width: CGFloat(viewport.width), height: CGFloat(viewport.height))
        )
    }
}

private struct ViewportFrameHeader: View {
    let viewport: APIClient.VisualViewportDTO
    let trailing: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: viewportFrameIcon(viewport.name))
                .foregroundStyle(.secondary)
            Text("\(viewport.name.capitalized) \(viewport.width)x\(viewport.height)")
                .font(.caption.bold())
            Spacer()
            Text(trailing)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func viewportFrameIcon(_ name: String) -> String {
        switch name {
        case "desktop": "desktopcomputer"
        case "tablet": "ipad"
        case "mobile": "iphone"
        default: "rectangle"
        }
    }
}

private struct LiveViewportWebView: NSViewRepresentable {
    let url: URL
    let viewport: APIClient.VisualViewportDTO

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")
        webView.load(request)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        if context.coordinator.currentURL != url {
            webView.load(request)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(url: url)
    }

    private var request: URLRequest {
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        return request
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var currentURL: URL

        init(url: URL) {
            currentURL = url
        }

        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            currentURL = webView.url ?? currentURL
        }
    }
}

private struct SnapshotColorChip: View {
    let color: SnapshotColor

    var body: some View {
        Button {
            copy(color.hex)
            AppStore.shared.uiStateStore.showInfo("Copied \(color.hex).")
        } label: {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color(hexString: color.hex) ?? .secondary.opacity(0.2))
                    .frame(width: 28, height: 28)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(.secondary.opacity(0.2), lineWidth: 1)
                    )

                VStack(alignment: .leading, spacing: 2) {
                    Text(color.hex.uppercased())
                        .font(.system(.caption, design: .monospaced).weight(.semibold))
                    if color.source != color.hex {
                        Text(color.source)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "doc.on.doc")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(7)
            .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .help("Copy \(color.hex)")
    }
}

private struct MetricPill: View {
    let label: String
    let value: Int

    var body: some View {
        VStack(spacing: 2) {
            Text("\(value)")
                .font(.caption.bold())
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 58)
        .padding(.vertical, 6)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 6))
    }
}

private struct ComponentGroup: Identifiable {
    let title: String
    let icon: String
    let samples: [APIClient.VisualElementSampleDTO]

    var id: String { title }
}

private struct ComponentGroupView: View {
    let group: ComponentGroup

    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(group.samples.prefix(12))) { sample in
                    ElementSampleRow(sample: sample)
                }
            }
            .padding(.top, 6)
        } label: {
            HStack(spacing: 8) {
                Label(group.title, systemImage: group.icon)
                    .font(.caption.bold())
                Spacer()
                Text("\(group.samples.count)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(8)
        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 7))
    }
}

private struct InspectorList: View {
    let title: String
    let values: [String]

    var body: some View {
        if !values.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.caption2.bold())
                    .foregroundStyle(.secondary)
                ForEach(values, id: \.self) { value in
                    CopyRow(value: value, systemImage: "doc.on.doc")
                }
            }
        }
    }
}

private struct CopyRow: View {
    let value: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .foregroundStyle(.secondary)
                .frame(width: 18)
            Text(value)
                .font(.caption)
                .lineLimit(2)
                .textSelection(.enabled)
            Spacer(minLength: 0)
            Button {
                copy(value)
                AppStore.shared.uiStateStore.showInfo("Copied.")
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
    }
}

private struct AssetList: View {
    let title: String
    let assets: [APIClient.VisualAssetDTO]

    var body: some View {
        if !assets.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.caption2.bold())
                    .foregroundStyle(.secondary)

                ForEach(assets.prefix(60)) { asset in
                    VStack(alignment: .leading, spacing: 4) {
                        CopyRow(value: asset.url ?? asset.selectorHint ?? title, systemImage: icon)

                        let details = assetDetails(asset)
                        if !details.isEmpty {
                            Text(details.joined(separator: "  |  "))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                                .textSelection(.enabled)
                        }
                    }
                    .padding(7)
                    .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 7))
                }
            }
        }
    }

    private var icon: String {
        switch title.lowercased() {
        case let value where value.contains("image"):
            "photo"
        case let value where value.contains("script"):
            "chevron.left.forwardslash.chevron.right"
        case let value where value.contains("style"):
            "curlybraces"
        default:
            "link"
        }
    }

    private func assetDetails(_ asset: APIClient.VisualAssetDTO) -> [String] {
        var details: [String] = []
        if let alt = asset.alt, !alt.isEmpty { details.append("alt: \(alt)") }
        if let width = asset.width, let height = asset.height, width > 0 || height > 0 {
            details.append("\(width)x\(height)")
        }
        if let loading = asset.loading, !loading.isEmpty { details.append("loading: \(loading)") }
        if let rel = asset.rel, !rel.isEmpty { details.append("rel: \(rel)") }
        if let sizes = asset.sizes, !sizes.isEmpty { details.append("sizes: \(sizes)") }
        if let type = asset.type, !type.isEmpty { details.append("type: \(type)") }
        if let media = asset.media, !media.isEmpty { details.append("media: \(media)") }
        if asset.isAsync == true { details.append("async") }
        if asset.isDeferred == true { details.append("defer") }
        if let selector = asset.selectorHint, !selector.isEmpty { details.append(selector) }
        return details
    }
}

private struct MetaList: View {
    let title: String
    let items: [APIClient.VisualMetaDTO]

    var body: some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.caption2.bold())
                    .foregroundStyle(.secondary)

                ForEach(items.prefix(80)) { item in
                    CopyRow(value: "\(item.name ?? "meta"): \(item.content ?? "")", systemImage: "tag")
                }
            }
        }
    }
}

private struct A11yItemList: View {
    let title: String
    let items: [APIClient.VisualAccessibilityItemDTO]

    var body: some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.caption2.bold())
                    .foregroundStyle(.secondary)

                ForEach(items.prefix(80)) { item in
                    let detail = [
                        item.selectorHint,
                        item.type.map { "type: \($0)" },
                        item.name.map { "name: \($0)" },
                        item.placeholder.map { "placeholder: \($0)" },
                        item.text.map { "text: \($0)" },
                    ]
                    .compactMap { $0 }
                    .filter { !$0.isEmpty }
                    .joined(separator: "  |  ")

                    CopyRow(value: detail.isEmpty ? title : detail, systemImage: "exclamationmark.triangle")
                }
            }
        }
    }
}

private struct HeadingSkipList: View {
    let skips: [APIClient.VisualHeadingSkipDTO]

    var body: some View {
        if !skips.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("Heading Level Skips")
                    .font(.caption2.bold())
                    .foregroundStyle(.secondary)

                ForEach(skips.prefix(40)) { skip in
                    let from = skip.from.map { "H\($0.level): \($0.text)" } ?? "Unknown"
                    let to = skip.to.map { "H\($0.level): \($0.text)" } ?? "Unknown"
                    CopyRow(value: "\(from) -> \(to)", systemImage: "textformat.123")
                }
            }
        }
    }
}

private struct NetworkRequestList: View {
    let title: String
    let requests: [APIClient.VisualNetworkRequestDTO]

    var body: some View {
        if !requests.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.caption2.bold())
                    .foregroundStyle(.secondary)

                ForEach(requests.prefix(60)) { request in
                    VStack(alignment: .leading, spacing: 4) {
                        CopyRow(value: request.url ?? title, systemImage: "network")

                        Text(details(request).joined(separator: "  |  "))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .textSelection(.enabled)
                    }
                    .padding(7)
                    .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 7))
                }
            }
        }
    }

    private func details(_ request: APIClient.VisualNetworkRequestDTO) -> [String] {
        var details: [String] = []
        if let method = request.method, !method.isEmpty { details.append(method) }
        if let status = request.status { details.append("status: \(status)") }
        if let type = request.resourceType, !type.isEmpty { details.append(type) }
        if let contentType = request.contentType, !contentType.isEmpty { details.append(contentType) }
        if let length = request.contentLength { details.append("\(length / 1024) KB") }
        if let failure = request.failure, !failure.isEmpty { details.append(failure) }
        return details
    }
}

private struct ElementSampleRow: View {
    let sample: APIClient.VisualElementSampleDTO

    private var cssText: String {
        """
        \(sample.selectorHint) {
          display: \(sample.display);
          position: \(sample.position);
          color: \(cssColor(sample.color));
          background-color: \(cssColor(sample.backgroundColor));
          font-family: \(sample.fontFamily);
          font-size: \(sample.fontSize);
          font-weight: \(sample.fontWeight);
          line-height: \(sample.lineHeight);
          letter-spacing: \(sample.letterSpacing);
          text-transform: \(sample.textTransform);
          margin: \(sample.margin);
          padding: \(sample.padding);
          border-radius: \(sample.borderRadius);
          box-shadow: \(sample.boxShadow);
        }
        """
    }

    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 8) {
                if !sample.text.isEmpty {
                    Text(sample.text)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }

                Text("x \(sample.x), y \(sample.y), \(sample.width)x\(sample.height)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                Text(cssText)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 6))

                Button {
                    copy(cssText)
                    AppStore.shared.uiStateStore.showInfo("CSS copied.")
                } label: {
                    Label("Copy CSS", systemImage: "doc.on.doc")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
            }
            .padding(.top, 6)
        } label: {
            HStack(spacing: 8) {
                Text(sample.selectorHint)
                    .font(.system(.caption, design: .monospaced).weight(.semibold))
                    .lineLimit(1)
                Text(sample.tag)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(sample.width)x\(sample.height)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(8)
        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 7))
    }

    private func cssColor(_ value: String) -> String {
        SnapshotColor.normalize(value)?.hex ?? value
    }
}

private struct SnapshotColor: Identifiable, Hashable {
    let hex: String
    let source: String

    var id: String { hex }

    static func unique(from values: [String]) -> [SnapshotColor] {
        var seen = Set<String>()
        var result: [SnapshotColor] = []
        for value in values {
            guard let color = normalize(value), !seen.contains(color.hex) else { continue }
            seen.insert(color.hex)
            result.append(color)
        }
        return result
    }

    static func normalize(_ value: String) -> SnapshotColor? {
        let raw = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty, raw.lowercased() != "transparent" else { return nil }

        if raw.hasPrefix("#") {
            var hex = raw
            if hex.count == 4 {
                let chars = Array(hex.dropFirst())
                hex = "#" + chars.map { "\($0)\($0)" }.joined()
            }
            guard hex.count == 7 else { return nil }
            return SnapshotColor(hex: hex.lowercased(), source: raw)
        }

        guard raw.lowercased().hasPrefix("rgb") else { return nil }
        let body = raw
            .replacingOccurrences(of: "rgba", with: "")
            .replacingOccurrences(of: "rgb", with: "")
            .replacingOccurrences(of: "(", with: "")
            .replacingOccurrences(of: ")", with: "")
        let parts = body
            .split { char in char == "," || char == " " || char == "/" }
            .compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard parts.count >= 3 else { return nil }
        if parts.count >= 4, parts[3] == 0 { return nil }
        let r = max(0, min(255, Int(parts[0].rounded())))
        let g = max(0, min(255, Int(parts[1].rounded())))
        let b = max(0, min(255, Int(parts[2].rounded())))
        return SnapshotColor(hex: String(format: "#%02x%02x%02x", r, g, b), source: raw)
    }
}

private extension Color {
    init?(hexString: String) {
        var value = hexString.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("#") { value.removeFirst() }
        guard value.count == 6, let intValue = Int(value, radix: 16) else { return nil }
        let red = Double((intValue >> 16) & 0xff) / 255
        let green = Double((intValue >> 8) & 0xff) / 255
        let blue = Double(intValue & 0xff) / 255
        self.init(red: red, green: green, blue: blue)
    }
}

private func copy(_ value: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(value, forType: .string)
}

private func viewportPDFData(
    snapshot: APIClient.VisualSnapshotDTO,
    pages: [(viewport: APIClient.VisualViewportDTO, image: NSImage)]
) -> Data? {
    let data = NSMutableData()
    guard let consumer = CGDataConsumer(data: data) else { return nil }
    var mediaBox = CGRect(x: 0, y: 0, width: 595, height: 842)
    guard let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else { return nil }

    let margin: CGFloat = 36
    let titleHeight: CGFloat = 54
    let pageWidth: CGFloat = 595
    let imageWidth = pageWidth - margin * 2

    for page in pages {
        guard let cgImage = page.image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { continue }
        let imageSize = page.image.size
        let scale = imageWidth / max(imageSize.width, 1)
        let imageHeight = imageSize.height * scale
        let pageHeight = max(CGFloat(842), imageHeight + titleHeight + margin * 2)
        let pageRect = CGRect(x: 0, y: 0, width: pageWidth, height: pageHeight)

        context.beginPDFPage([kCGPDFContextMediaBox as String: pageRect] as CFDictionary)
        context.setFillColor(NSColor.textBackgroundColor.cgColor)
        context.fill(pageRect)

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        let title = "\(page.viewport.name.capitalized) \(page.viewport.width)x\(page.viewport.height)"
        let subtitle = snapshot.url
        (title as NSString).draw(
            in: CGRect(x: margin, y: pageHeight - margin - 22, width: imageWidth, height: 22),
            withAttributes: [
                .font: NSFont.boldSystemFont(ofSize: 14),
                .foregroundColor: NSColor.labelColor,
            ]
        )
        (subtitle as NSString).draw(
            in: CGRect(x: margin, y: pageHeight - margin - 42, width: imageWidth, height: 18),
            withAttributes: [
                .font: NSFont.systemFont(ofSize: 9),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]
        )
        NSGraphicsContext.restoreGraphicsState()

        let imageRect = CGRect(x: margin, y: margin, width: imageWidth, height: imageHeight)
        context.interpolationQuality = .high
        context.draw(cgImage, in: imageRect)
        context.endPDFPage()
    }

    context.closePDF()
    return data as Data
}

private func safeFilename(_ value: String) -> String {
    let illegal = CharacterSet(charactersIn: "/\\?%*|\"<>:")
    let cleaned = value
        .components(separatedBy: illegal)
        .joined(separator: "-")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    return cleaned.isEmpty ? "gyrus" : String(cleaned.prefix(80))
}

private func reviewPreviewSize(for viewport: APIClient.VisualViewportDTO) -> CGSize {
    let scale = reviewPreviewScale(for: viewport)
    return CGSize(
        width: CGFloat(viewport.width) * scale,
        height: CGFloat(viewport.height) * scale
    )
}

private func reviewPreviewScale(for viewport: APIClient.VisualViewportDTO) -> CGFloat {
    let viewportWidth = CGFloat(max(viewport.width, 1))
    let viewportHeight = CGFloat(max(viewport.height, 1))
    return min(
        1,
        max(0.18, reviewFrameMaxWidth(for: viewport) / viewportWidth),
        max(0.18, reviewFrameMaxHeight(for: viewport) / viewportHeight)
    )
}

private func reviewFrameMaxWidth(for viewport: APIClient.VisualViewportDTO) -> CGFloat {
    switch viewport.name {
    case "desktop":
        620
    case "tablet":
        340
    case "mobile":
        220
    default:
        min(CGFloat(viewport.width), 620)
    }
}

private func reviewFrameMaxHeight(for viewport: APIClient.VisualViewportDTO) -> CGFloat {
    switch viewport.name {
    case "desktop":
        420
    case "tablet":
        420
    case "mobile":
        420
    default:
        min(CGFloat(viewport.height), 560)
    }
}

private func frequency(_ values: [String], limit: Int = 8) -> [String] {
    let counts = Dictionary(grouping: values, by: { $0 }).mapValues(\.count)
    return counts
        .sorted { lhs, rhs in
            if lhs.value == rhs.value { return lhs.key < rhs.key }
            return lhs.value > rhs.value
        }
        .prefix(limit)
        .map { "\($0.key) (\($0.value)x)" }
}

private extension Array where Element == APIClient.VisualElementSampleDTO {
    func matching(_ needles: [String]) -> [APIClient.VisualElementSampleDTO] {
        filter { sample in
            let haystack = "\(sample.tag) \(sample.selectorHint) \(sample.text)".lowercased()
            return needles.contains { haystack.contains($0.lowercased()) }
        }
    }
}
