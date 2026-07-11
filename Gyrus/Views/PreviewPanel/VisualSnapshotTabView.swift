import SwiftUI
import AppKit

private enum DesignInspectorSection: String, CaseIterable, Identifiable {
    case overview
    case visual
    case colors
    case typography
    case components
    case layout
    case assets
    case seo
    case accessibility
    case raw

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: "Overview"
        case .visual: "Visual"
        case .colors: "Colors"
        case .typography: "Type"
        case .components: "Components"
        case .layout: "Layout"
        case .assets: "Assets"
        case .seo: "SEO"
        case .accessibility: "A11y"
        case .raw: "Raw"
        }
    }

    var icon: String {
        switch self {
        case .overview: "rectangle.grid.2x2"
        case .visual: "photo"
        case .colors: "eyedropper"
        case .typography: "textformat"
        case .components: "square.stack.3d.up"
        case .layout: "rectangle.3.group"
        case .assets: "photo.on.rectangle.angled"
        case .seo: "magnifyingglass"
        case .accessibility: "accessibility"
        case .raw: "curlybraces.square"
        }
    }
}

struct VisualSnapshotTabView: View {
    let bookmark: Bookmark

    @State private var snapshot: APIClient.VisualSnapshotDTO?
    @State private var selectedViewportName: String?
    @State private var selectedSection: DesignInspectorSection = .overview
    @State private var isLoading = false
    @State private var isCapturing = false

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
                viewportPicker
                sectionPicker

                if let selectedViewport {
                    switch selectedSection {
                    case .overview:
                        overviewSection(selectedViewport)
                    case .visual:
                        screenshotSection(selectedViewport)
                    case .colors:
                        colorsSection
                    case .typography:
                        typographySection(selectedViewport)
                    case .components:
                        componentsSection(selectedViewport)
                    case .layout:
                        layoutSection(selectedViewport)
                    case .assets:
                        assetsSection(selectedViewport)
                    case .seo:
                        seoSection(selectedViewport)
                    case .accessibility:
                        accessibilitySection(selectedViewport)
                    case .raw:
                        elementSamplesSection(selectedViewport)
                    }
                }
            }
            .padding(16)
        }
    }

    private var sectionPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(DesignInspectorSection.allCases) { section in
                    Button {
                        selectedSection = section
                    } label: {
                        Label(section.title, systemImage: section.icon)
                            .labelStyle(.titleAndIcon)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(selectedSection == section ? .white : .primary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(
                                selectedSection == section ? Color.accentColor : Color.secondary.opacity(0.14),
                                in: RoundedRectangle(cornerRadius: 6)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    @ViewBuilder
    private var viewportPicker: some View {
        if let snapshot, snapshot.viewports.count > 1 {
            HStack(spacing: 6) {
                ForEach(snapshot.viewports, id: \.name) { viewport in
                    Button {
                        selectedViewportName = viewport.name
                    } label: {
                        Text("\(viewport.name.capitalized) \(viewport.width)x\(viewport.height)")
                            .font(.caption.weight(.medium))
                            .foregroundStyle((selectedViewport?.name == viewport.name) ? .white : .primary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(
                                (selectedViewport?.name == viewport.name ? Color.accentColor : Color.secondary.opacity(0.16)),
                                in: RoundedRectangle(cornerRadius: 6)
                            )
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
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
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 116), spacing: 8)], spacing: 8) {
                    MetricPill(label: "Colors", value: colors.count)
                    MetricPill(label: "Fonts", value: viewport.observedFonts.count)
                    MetricPill(label: "Elements", value: viewport.elementSamples?.count ?? 0)
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
                HStack(spacing: 8) {
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
                HStack(spacing: 8) {
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
                HStack(spacing: 8) {
                    MetricPill(label: "Images", value: viewport.structure.images)
                    MetricPill(label: "SVG", value: viewport.structure.svgs)
                }
                Text("Next phase: extract image URLs, logo candidates, SVG/icon usage, OG images, dimensions and asset file sizes from the DevTools capture.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func seoSection(_ viewport: APIClient.VisualViewportDTO) -> some View {
        SnapshotSection(title: "SEO / Content", icon: "magnifyingglass") {
            VStack(alignment: .leading, spacing: 8) {
                if let pageTitle = viewport.pageTitle, !pageTitle.isEmpty {
                    CopyRow(value: "Title: \(pageTitle)", systemImage: "textformat.size")
                }
                if let metaDescription = viewport.metaDescription, !metaDescription.isEmpty {
                    CopyRow(value: "Description: \(metaDescription)", systemImage: "text.quote")
                }
                structureSection(viewport)
                Text("Next phase: add canonical, OG/Twitter tags, JSON-LD, language, robots hints and internal/external link breakdown.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func accessibilitySection(_ viewport: APIClient.VisualViewportDTO) -> some View {
        SnapshotSection(title: "Accessibility", icon: "accessibility") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    MetricPill(label: "Buttons", value: viewport.structure.buttons)
                    MetricPill(label: "Images", value: viewport.structure.images)
                    MetricPill(label: "Forms", value: viewport.structure.forms)
                }
                Text("Next phase: run contrast checks, alt text detection, button/link names, form labels, heading order and tap target checks.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
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
        .frame(minWidth: 54)
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
