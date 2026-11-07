import SwiftUI
import AppKit

struct TechnologyCard: View {
    let technology: APIClient.VisualTechnologyDTO

    private var confidenceColor: Color {
        technology.confidence == "high" ? .green : .orange
    }

    private var evidenceSummary: String {
        technology.evidence.joined(separator: "\n")
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(confidenceColor)
                .frame(width: 7, height: 7)
                .padding(.top, 5)

            VStack(alignment: .leading, spacing: 2) {
                (pageText(technology.name, localize: true)
                    + Text(technology.version.map { " \($0)" } ?? ""))
                    .font(.caption.weight(.semibold))
                    .lineLimit(2)
                pageText(technology.category, localize: true)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
        .padding(9)
        .frame(maxWidth: .infinity, minHeight: 48, alignment: .topLeading)
        .background(Color.secondary.opacity(0.10), in: RoundedRectangle(cornerRadius: 7))
        .help(evidenceSummary)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(technology.name), \(technology.category)")
        .accessibilityHint(evidenceSummary)
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
                    AppStore.shared.uiStateStore.showInfo(String(localized: "CSS copied."))
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

    var boxWidth: CGFloat = 92
    var boxHeight: CGFloat = 58

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
        .task(id: "\(screenshotPath)|\(sample.id)") {
            image = nil
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

struct ComponentGroup: Identifiable {
    let title: String
    let icon: String
    let variants: [ComponentVariant]

    var id: String { title }
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
                AppStore.shared.uiStateStore.showInfo(String(localized: "Copied."))
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

                ForEach(Array(assets.prefix(60).enumerated()), id: \.offset) { _, asset in
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

                ForEach(Array(items.prefix(80).enumerated()), id: \.offset) { _, item in
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

                ForEach(Array(items.prefix(80).enumerated()), id: \.offset) { _, item in
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

/// The computed styles of one sampled element as a CSS rule, for copying.
func elementSampleCSS(_ sample: APIClient.VisualElementSampleDTO) -> String {
    func color(_ value: String) -> String {
        SnapshotColor.normalize(value)?.hex ?? value
    }
    return """
    \(sample.selectorHint) {
      display: \(sample.display);
      position: \(sample.position);
      color: \(color(sample.color));
      background-color: \(color(sample.backgroundColor));
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
