import SwiftUI
import AppKit

struct SnapshotColorChip: View {
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

struct PaletteChip: View {
    let entry: PaletteEntry

    var body: some View {
        Button {
            copy(entry.hex)
            AppStore.shared.uiStateStore.showInfo("Copied \(entry.hex).")
        } label: {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color(hexString: entry.hex) ?? .secondary.opacity(0.2))
                    .frame(width: 28, height: 28)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(.secondary.opacity(0.2), lineWidth: 1)
                    )

                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.hex.uppercased())
                        .font(.system(.caption, design: .monospaced).weight(.semibold))
                    if !entry.caption.isEmpty {
                        Text(verbatim: entry.caption)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                Spacer(minLength: 0)
                if entry.occurrences > 1 {
                    Text(verbatim: "\(entry.occurrences)x")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(7)
            .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .help("Copy \(entry.hex)")
    }
}

struct PaletteBand: View {
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey
    let entries: [PaletteEntry]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.caption2.bold())
                    .foregroundStyle(.secondary)
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 132), spacing: 8)], spacing: 8) {
                ForEach(entries) { entry in
                    PaletteChip(entry: entry)
                }
            }
        }
    }
}

struct TypeScaleRow: View {
    let step: TypeScaleStep

    /// The panel is ~500pt wide, so a 96px heading is rendered at a readable
    /// stand-in size rather than at its true size. The number stays exact in the
    /// metrics line underneath.
    private var previewSize: CGFloat {
        min(max(CGFloat(step.pixels), 11), 30)
    }

    private var weight: Font.Weight {
        switch Int(step.fontWeight) ?? 400 {
        case ..<300: .light
        case 300..<400: .regular
        case 400..<500: .regular
        case 500..<600: .medium
        case 600..<700: .semibold
        case 700..<800: .bold
        default: .heavy
        }
    }

    private var metrics: String {
        var parts = [step.fontSize, step.fontWeight]
        if !step.lineHeight.isEmpty, step.lineHeight != "normal" { parts.append(step.lineHeight) }
        if !step.letterSpacing.isEmpty, step.letterSpacing != "normal" { parts.append(step.letterSpacing) }
        parts.append("\(step.occurrences)x")
        return parts.joined(separator: "  ·  ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: step.specimen.isEmpty ? "Aa Bb Cc 123" : step.specimen)
                .font(.system(size: previewSize, weight: weight))
                .lineLimit(1)
                .truncationMode(.tail)
                .textSelection(.enabled)

            HStack(spacing: 8) {
                Text(verbatim: metrics)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Button {
                    copy(step.css)
                    AppStore.shared.uiStateStore.showInfo("CSS copied.")
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tertiary)
                .help("Copy CSS")
            }

            Text(verbatim: step.fontFamily)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 7))
    }
}

/// The component as it actually looks, cut out of the page screenshot.
///
/// A component inventory without pictures is a list of selectors — and on a
/// utility-CSS site those selectors carry no meaning at all. Everything needed
/// was already captured: the full-page image and each element's rectangle.
struct ComponentThumbnail: View {
    let sample: APIClient.VisualElementSampleDTO
    let screenshotPath: String
    let viewportWidth: Int

    @State private var image: NSImage?
    @State private var isLoading = true

    private let boxWidth: CGFloat = 92
    private let boxHeight: CGFloat = 58

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else if isLoading {
                ProgressView().scaleEffect(0.4)
            } else {
                Image(systemName: "rectangle.dashed")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(width: boxWidth, height: boxHeight)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .overlay(
            RoundedRectangle(cornerRadius: 5)
                .stroke(.secondary.opacity(0.22), lineWidth: 1)
        )
        .task(id: sample.id) {
            isLoading = true
            defer { isLoading = false }
            guard let full = await SnapshotImageStore.shared.image(atPath: screenshotPath) else { return }
            image = SnapshotImageStore.shared.crop(
                full,
                x: sample.x, y: sample.y, width: sample.width, height: sample.height,
                viewportWidth: viewportWidth
            )
        }
    }
}

struct MetricPill: View {
    let label: String
    let value: Int

    var body: some View {
        VStack(spacing: 2) {
            Text("\(value)")
                .font(.caption.bold())
            Text(LocalizedStringKey(label))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 58)
        .padding(.vertical, 6)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 6))
    }
}

struct ComponentGroup: Identifiable {
    let title: String
    let icon: String
    let variants: [ComponentVariant]
    /// Instances before collapsing, so the header can say "3 patterns, 11 uses".
    let instanceCount: Int

    var id: String { title }
}

struct ComponentGroupView: View {
    let group: ComponentGroup
    let screenshotPath: String
    let viewportWidth: Int

    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(group.variants) { variant in
                    ElementSampleRow(
                        sample: variant.representative,
                        variant: variant,
                        screenshotPath: screenshotPath,
                        viewportWidth: viewportWidth
                    )
                }
            }
            .padding(.top, 6)
        } label: {
            HStack(spacing: 8) {
                Label(LocalizedStringKey(group.title), systemImage: group.icon)
                    .font(.caption.bold())
                Spacer()
                if group.instanceCount != group.variants.count {
                    Text(verbatim: "\(group.variants.count) / \(group.instanceCount)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .help("Distinct patterns / instances found")
                } else {
                    Text(verbatim: "\(group.variants.count)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(8)
        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 7))
    }
}

struct CSSVariableGroupView: View {
    let group: CSSVariableGroup
    @State private var isExpanded: Bool

    init(group: CSSVariableGroup) {
        self.group = group
        _isExpanded = State(initialValue: !group.collapsed)
    }

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 5) {
                ForEach(group.variables) { variable in
                    HStack(spacing: 8) {
                        if let color = SnapshotColor.normalize(variable.value) {
                            RoundedRectangle(cornerRadius: 3)
                                .fill(Color(hexString: color.hex) ?? .clear)
                                .frame(width: 14, height: 14)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 3)
                                        .stroke(.secondary.opacity(0.25), lineWidth: 1)
                                )
                        }
                        Text(verbatim: variable.name)
                            .font(.system(.caption2, design: .monospaced).weight(.semibold))
                            .lineLimit(1)
                        Text(verbatim: variable.value)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 0)
                        Button {
                            copy("\(variable.name): \(variable.value)")
                            AppStore.shared.uiStateStore.showInfo("Copied.")
                        } label: {
                            Image(systemName: "doc.on.doc")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.tertiary)
                    }
                }
            }
            .padding(.top, 6)
        } label: {
            HStack(spacing: 8) {
                Text(group.title)
                    .font(.caption2.bold())
                    .foregroundStyle(.secondary)
                Spacer()
                Text(verbatim: "\(group.variables.count)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

struct InspectorList: View {
    let title: String
    let values: [String]

    var body: some View {
        if !values.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text(LocalizedStringKey(title))
                    .font(.caption2.bold())
                    .foregroundStyle(.secondary)
                ForEach(values, id: \.self) { value in
                    CopyRow(value: value)
                }
            }
        }
    }
}

struct CopyRow: View {
    let value: String
    /// Optional: `CopyRow` always draws a trailing copy button, so a leading
    /// "doc.on.doc" would put two identical icons on the same row. Pass an icon
    /// only when it says something the text does not.
    var systemImage: String? = nil

    var body: some View {
        HStack(spacing: 8) {
            if let systemImage {
                Image(systemName: systemImage)
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
            }
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

struct AssetList: View {
    let title: String
    let assets: [APIClient.VisualAssetDTO]

    var body: some View {
        if !assets.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text(LocalizedStringKey(title))
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

    func assetDetails(_ asset: APIClient.VisualAssetDTO) -> [String] {
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

struct MetaList: View {
    let title: String
    let items: [APIClient.VisualMetaDTO]

    var body: some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text(LocalizedStringKey(title))
                    .font(.caption2.bold())
                    .foregroundStyle(.secondary)

                ForEach(items.prefix(80)) { item in
                    CopyRow(value: "\(item.name ?? "meta"): \(item.content ?? "")", systemImage: "tag")
                }
            }
        }
    }
}

struct A11yItemList: View {
    let title: String
    let items: [APIClient.VisualAccessibilityItemDTO]

    var body: some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text(LocalizedStringKey(title))
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

struct HeadingSkipList: View {
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

struct NetworkRequestList: View {
    let title: String
    let requests: [APIClient.VisualNetworkRequestDTO]

    var body: some View {
        if !requests.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text(LocalizedStringKey(title))
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

    func details(_ request: APIClient.VisualNetworkRequestDTO) -> [String] {
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

struct ElementSampleRow: View {
    let sample: APIClient.VisualElementSampleDTO
    /// Present when this row stands for several identical instances.
    var variant: ComponentVariant? = nil
    /// Set to show a cut-out of the element; empty disables the thumbnail.
    var screenshotPath: String = ""
    var viewportWidth: Int = 0

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
                if let variant, variant.texts.count > 1 {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Copy across instances")
                            .font(.caption2.bold())
                            .foregroundStyle(.secondary)
                        ForEach(variant.texts.prefix(8), id: \.self) { text in
                            Text(verbatim: "· \(text)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .textSelection(.enabled)
                        }
                    }
                } else if !sample.text.isEmpty {
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
                if !screenshotPath.isEmpty, viewportWidth > 0 {
                    ComponentThumbnail(
                        sample: sample,
                        screenshotPath: screenshotPath,
                        viewportWidth: viewportWidth
                    )
                }
                Text(verbatim: sample.selectorHint)
                    .font(.system(.caption, design: .monospaced).weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(verbatim: sample.tag)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if let variant, variant.count > 1 {
                    Text(verbatim: "\(variant.count)x")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.accentColor.opacity(0.14), in: Capsule())
                }
                Spacer()
                Text(verbatim: "\(sample.width)x\(sample.height)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(8)
        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 7))
    }

    func cssColor(_ value: String) -> String {
        SnapshotColor.normalize(value)?.hex ?? value
    }
}
