import SwiftUI

/// One visual swatch per normalized RGB value; retain every source label.
struct InspectorPaletteColor: Identifiable {
    let hex: String
    let labels: [String]
    var id: String { hex }

    static func luminance(_ hex: String) -> Double {
        guard let value = UInt32(hex.dropFirst(), radix: 16) else { return 0 }
        func linear(_ byte: UInt32) -> Double {
            let channel = Double(byte) / 255
            return channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear((value >> 16) & 255)
            + 0.7152 * linear((value >> 8) & 255) + 0.0722 * linear(value & 255)
    }

    static func preview(_ sorted: [Self], limit: Int = 12) -> [Self] {
        guard limit > 1, sorted.count > limit else { return Array(sorted.prefix(max(0, limit))) }
        return (0..<limit).map { sorted[$0 * (sorted.count - 1) / (limit - 1)] }
    }

    static func grouped(_ entries: [PaletteEntry]) -> [Self] {
        var labels: [String: Set<String>] = [:]
        for entry in entries {
            guard let color = SnapshotColor.normalize(entry.hex) else { continue }
            labels[color.hex, default: []].formUnion(entry.caption.isEmpty ? [] : [entry.caption])
        }
        return labels.map { Self(hex: $0.key, labels: $0.value.sorted()) }.sorted {
            let left = luminance($0.hex), right = luminance($1.hex)
            return left == right ? $0.hex < $1.hex : left < right
        }
    }
}

/// Bounded pages prevent a single category from turning into a data dump.
struct InspectorPage<Item: Identifiable, Content: View>: View {
    let items: [Item]
    var pageSize = 8
    var grid = false
    var minimumCardWidth: CGFloat = 145
    var columnCount: Int? = nil
    @ViewBuilder let row: (Item) -> Content
    @State private var page = 0

    private var current: Int { min(page, max(0, (items.count - 1) / pageSize)) }
    private var start: Int { current * pageSize }
    private var end: Int { min(start + pageSize, items.count) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if items.isEmpty {
                Text("No matching captured data.").font(.callout).foregroundStyle(.secondary)
            } else {
                HStack {
                    Text("\(start + 1)–\(end) of \(items.count)")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if items.count > pageSize {
                        Button { page = current - 1 } label: { Image(systemName: "chevron.left") }
                            .disabled(current == 0).accessibilityLabel("Previous page")
                        Button { page = current + 1 } label: { Image(systemName: "chevron.right") }
                            .disabled(end == items.count).accessibilityLabel("Next page")
                    }
                }.buttonStyle(.bordered).controlSize(.small)
                if grid {
                    LazyVGrid(columns: columnCount.map { Array(repeating: GridItem(.flexible(), spacing: 10), count: $0) }
                        ?? [GridItem(.adaptive(minimum: minimumCardWidth), spacing: 10)], spacing: 10) {
                        ForEach(Array(items[start..<end]), content: row)
                    }
                } else {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(items[start..<end]), content: row)
                    }
                }
            }
        }
        .onChange(of: items.map(\.id)) { _, _ in page = 0 }
    }
}

struct InspectorField: View {
    let title: LocalizedStringKey
    let value: String
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            if value.isEmpty {
                Text("Not captured").font(.caption).foregroundStyle(.tertiary)
            } else {
                CopyRow(value: value).help(value)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct InspectorString: Identifiable {
    let id: Int
    let value: String
    static func rows(_ strings: [String]) -> [Self] {
        strings.enumerated().map { Self(id: $0.offset, value: $0.element) }
    }
}

struct DesignSystemBrowser: View {
    let viewport: APIClient.VisualViewportDTO
    @State private var section = "Overview"
    @State private var colorSource = "Design tokens"
    @State private var query = ""
    @State private var variableGroup = "all"
    private let sections = ["Overview", "Colors", "Type", "Layout", "CSS"]
    private var samples: [APIClient.VisualElementSampleDTO] { viewport.elementSamples ?? [] }
    private var tokens: [PaletteEntry] { (viewport.cssVariables ?? []).colorTokens(limit: .max) }
    private var painted: [PaletteEntry] { samples.paintedPalette(limit: .max) }
    private var palette: [InspectorPaletteColor] {
        let entries: [PaletteEntry]
        switch colorSource {
        case "In use": entries = painted
        case "Screenshot": entries = SnapshotColor.unique(from: viewport.dominantColors).map {
            PaletteEntry(hex: $0.hex, caption: $0.source, area: 0, occurrences: 1)
        }
        default: entries = tokens
        }
        return InspectorPaletteColor.grouped(entries)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("System area", selection: $section) {
                ForEach(sections, id: \.self) { Text(LocalizedStringKey($0)).tag($0) }
            }.pickerStyle(.segmented).labelsHidden()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    switch section {
                    case "Colors": colors
                    case "Type": typography
                    case "Layout": layout
                    case "CSS": variables
                    default: overview
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.bottom, 16)
            }.id(section)
        }
        .onChange(of: section) { _, _ in query = "" }
        .onAppear { if tokens.isEmpty { colorSource = "In use" } }
    }

    private var overview: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("The visual essentials. Choose an area above for exact values.")
                .font(.callout).foregroundStyle(.secondary)
            SnapshotSection(title: "Palette", icon: "paintpalette") {
                let colors = InspectorPaletteColor.grouped(tokens.isEmpty ? painted : tokens)
                if colors.isEmpty {
                    Text("No colors captured.").font(.caption).foregroundStyle(.secondary)
                } else {
                    HStack(spacing: 3) {
                        ForEach(InspectorPaletteColor.preview(colors)) { color in
                            RoundedRectangle(cornerRadius: 4).fill(Color(hexString: color.hex) ?? .clear)
                                .frame(height: 32).help(color.hex.uppercased())
                                .accessibilityLabel(color.hex.uppercased())
                        }
                    }
                    Button("Explore \(colors.count) colors") { section = "Colors" }
                        .buttonStyle(.borderless)
                }
            }
            SnapshotSection(title: "Typography", icon: "textformat") {
                let families = Array(Set(samples.map(\.fontFamily).filter { !$0.isEmpty } + viewport.observedFonts)).sorted()
                Text(families.prefix(2).joined(separator: "\n")).font(.callout).lineLimit(3)
                Text(samples.typeScale(limit: .max).map(\.fontSize).uniqued().joined(separator: " · "))
                    .font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(2)
                Button("Explore typography") { section = "Type" }.buttonStyle(.borderless)
            }
            SnapshotSection(title: "Architecture", icon: "cpu") {
                if let technologies = viewport.technologies, !technologies.isEmpty {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 8)], spacing: 8) {
                        ForEach(technologies) { TechnologyCard(technology: $0) }
                    }
                } else {
                    Text("No technology signatures detected.").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var colors: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Color source", selection: $colorSource) {
                Text("Design tokens").tag("Design tokens")
                Text("In use").tag("In use")
                Text("Screenshot").tag("Screenshot")
            }.pickerStyle(.menu)
            Text("Dark to light. Identical HEX values are combined. Click a color to copy it.")
                .font(.caption).foregroundStyle(.secondary)
            if colorSource == "Screenshot" {
                Text("Averaged from the rendered image, not exact values").font(.caption).foregroundStyle(.secondary)
            }
            TextField("Find HEX or variable…", text: $query).textFieldStyle(.roundedBorder)
            InspectorPage(items: palette.filter { query.isEmpty || $0.hex.localizedCaseInsensitiveContains(query) || $0.labels.contains { $0.localizedCaseInsensitiveContains(query) } }, pageSize: 12, grid: true, minimumCardWidth: 104) { entry in
                InspectorColorCard(entry: entry)
            }.id(colorSource)
        }
    }

    private var typography: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Captured type styles, largest first. Previews use the system font; CSS values remain exact.")
                .font(.caption).foregroundStyle(.secondary)
            let scale = samples.typeScale(limit: .max)
            InspectorPage(items: scale, pageSize: 5) { TypeScaleRow(step: $0) }
            DisclosureGroup("All font stacks") {
                InspectorPage(items: InspectorString.rows(viewport.observedFonts), pageSize: 6) { CopyRow(value: $0.value) }
            }.font(.caption)
        }
    }

    private var layout: some View {
        VStack(alignment: .leading, spacing: 16) {
            InspectorField(title: "Viewport", value: "\(viewport.width) × \(viewport.height) px")
            InspectorField(title: "Spacing Scale", value: samples.spacingScale().joined(separator: " · "))
            InspectorField(title: "Radius Patterns", value: frequency(samples.map(\.borderRadius).filter { !$0.isEmpty }).joined(separator: " · "))
            InspectorField(title: "Display Patterns", value: frequency(samples.map(\.display).filter { !$0.isEmpty }).joined(separator: " · "))
        }
    }

    private var variables: some View {
        let groups = groupCSSVariables(viewport.cssVariables ?? [])
        let values = variableGroup == "all" ? (viewport.cssVariables ?? []) : (groups.first { $0.key == variableGroup }?.variables ?? [])
        return VStack(alignment: .leading, spacing: 12) {
            Text("Technical reference: search a variable instead of scrolling through every CSS value.")
                .font(.caption).foregroundStyle(.secondary)
            Picker("Variable group", selection: $variableGroup) {
                Text("All").tag("all")
                ForEach(groups) { Text($0.title).tag($0.key) }
            }.pickerStyle(.menu)
            TextField("Find variable or value…", text: $query).textFieldStyle(.roundedBorder)
            let filtered = values.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) || $0.value.localizedCaseInsensitiveContains(query) }
            let sorted = filtered.sorted {
                let a = SnapshotColor.normalize($0.value), b = SnapshotColor.normalize($1.value)
                if (a != nil) != (b != nil) { return a != nil }
                if let a, let b {
                    let l = InspectorPaletteColor.luminance(a.hex), r = InspectorPaletteColor.luminance(b.hex)
                    if l != r { return l < r }
                }
                return $0.name < $1.name
            }
            InspectorPage(items: sorted, pageSize: 8) { variable in
                InspectorField(title: LocalizedStringKey(variable.name), value: variable.value)
            }
        }
    }
}

private struct InspectorColorCard: View {
    let entry: InspectorPaletteColor
    @State private var showLabels = false
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                copy(entry.hex.uppercased())
                AppStore.shared.uiStateStore.showInfo("Copied.")
            } label: {
                VStack(alignment: .leading, spacing: 6) {
                    RoundedRectangle(cornerRadius: 5).fill(Color(hexString: entry.hex) ?? .clear)
                        .frame(height: 32).overlay(RoundedRectangle(cornerRadius: 5).stroke(.secondary.opacity(0.3)))
                    Text(entry.hex.uppercased()).font(.system(.caption, design: .monospaced).weight(.semibold))
                }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel("Copy \(entry.hex)")
            if !entry.labels.isEmpty {
                Button("\(entry.labels.count) source labels") { showLabels = true }
                    .font(.caption2).buttonStyle(.borderless)
                    .popover(isPresented: $showLabels) {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(entry.hex.uppercased()).font(.headline)
                            ScrollView { VStack(alignment: .leading, spacing: 8) {
                                ForEach(entry.labels, id: \.self) { CopyRow(value: $0) }
                            } }.frame(maxHeight: 260)
                        }.padding(16).frame(width: 330)
                    }
            }
        }.padding(10).background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
    }
}

private extension Array where Element == String {
    func uniqued() -> [String] {
        var seen = Set<String>()
        return filter { seen.insert($0).inserted }
    }
}
