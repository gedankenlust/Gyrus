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
    let samples: [APIClient.VisualElementSampleDTO]

    var id: String { title }
}

struct ComponentGroupView: View {
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
                Label(LocalizedStringKey(group.title), systemImage: group.icon)
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
                    CopyRow(value: value, systemImage: "doc.on.doc")
                }
            }
        }
    }
}

struct CopyRow: View {
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

    func cssColor(_ value: String) -> String {
        SnapshotColor.normalize(value)?.hex ?? value
    }
}
