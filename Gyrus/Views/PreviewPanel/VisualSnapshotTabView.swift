import SwiftUI
import AppKit

struct VisualSnapshotTabView: View {
    let bookmark: Bookmark

    @State private var snapshot: APIClient.VisualSnapshotDTO?
    @State private var selectedViewportName: String?
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
                Label("Snapshot", systemImage: "camera.viewfinder")
                    .font(.headline)
                Spacer()
                if isCapturing {
                    ProgressView().scaleEffect(0.55)
                }
                Button {
                    Task { await captureSnapshot() }
                } label: {
                    Label(snapshot == nil ? "Capture" : "Recapture", systemImage: "camera.metering.center.weighted")
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
                Text("No design snapshot yet")
                    .font(.headline)
                Text("Capture the rendered page to inspect screenshots, colors, typography, layout and computed styles.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
            }
            Button {
                Task { await captureSnapshot() }
            } label: {
                Label("Capture Snapshot", systemImage: "camera.metering.center.weighted")
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

                if let selectedViewport {
                    screenshotSection(selectedViewport)
                    colorsSection
                    typographySection(selectedViewport)
                    structureSection(selectedViewport)
                    elementSamplesSection(selectedViewport)
                }
            }
            .padding(16)
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
