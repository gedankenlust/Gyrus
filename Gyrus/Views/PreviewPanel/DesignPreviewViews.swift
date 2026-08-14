import SwiftUI
import AppKit
import WebKit

struct SnapshotSection<Content: View>: View {
    let title: LocalizedStringKey
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

struct SnapshotViewportFrame: View {
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

struct LiveViewportFrame: View {
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

/// All captured viewports next to each other.
///
/// Three viewports were being captured and the panel could only switch between
/// them one at a time, which answers "what does this look like on mobile" but
/// not "what changes between desktop and mobile" — and the second question is
/// the one a responsive design actually has to answer.
struct ViewportComparisonStrip: View {
    let viewports: [APIClient.VisualViewportDTO]

    /// A common width rather than a common scale: at a shared scale the mobile
    /// frame would be a fifth of the desktop one and too small to read. Equal
    /// width makes the layouts comparable, and the true dimensions are printed
    /// under each frame.
    private let cellWidth: CGFloat = 148

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Each frame stops at its own fold, so the taller viewports show the
            // start of the next section while the desktop one does not. Without
            // saying so, that reads as a broken screenshot rather than as the
            // layout difference it is.
            Text("Each frame shows the first screenful at that viewport.")
                .font(.caption2)
                .foregroundStyle(.tertiary)

            comparisonRow
        }
    }

    private var comparisonRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 12) {
                ForEach(viewports, id: \.name) { viewport in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 5) {
                            Image(systemName: viewportComparisonIcon(viewport.name))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Text(verbatim: viewport.name.capitalized)
                                .font(.caption.weight(.semibold))
                        }

                        ViewportScreenshotImage(viewport: viewport)
                            .frame(
                                width: cellWidth,
                                height: cellWidth * CGFloat(max(viewport.height, 1)) / CGFloat(max(viewport.width, 1))
                            )
                            .background(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 7))
                            .overlay(
                                RoundedRectangle(cornerRadius: 7)
                                    .stroke(.secondary.opacity(0.25), lineWidth: 1)
                            )
                            .shadow(color: .black.opacity(0.1), radius: 6, y: 3)

                        Text(verbatim: "\(viewport.width)x\(viewport.height)")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .padding(.vertical, 2)
        }
    }

    private func viewportComparisonIcon(_ name: String) -> String {
        switch name {
        case "desktop": "desktopcomputer"
        case "tablet": "ipad"
        case "mobile": "iphone"
        default: "rectangle"
        }
    }
}

struct ViewportScreenshotImage: View {
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

    func loadImage() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        // Through the shared store: the comparison strip shows every viewport at
        // once, and the component thumbnails cut out of the same screenshots,
        // so each image should be fetched and decoded once.
        guard let source = await SnapshotImageStore.shared.image(atPath: viewport.screenshotURL) else {
            image = nil
            return
        }
        image = cropViewport(from: source, viewport: viewport) ?? source
    }

    func cropViewport(from source: NSImage, viewport: APIClient.VisualViewportDTO) -> NSImage? {
        guard let cgImage = source.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let scale = CGFloat(cgImage.width) / CGFloat(max(viewport.width, 1))
        let cropHeight = min(cgImage.height, Int((CGFloat(viewport.height) * scale).rounded()))
        guard cropHeight > 0 else { return nil }
        let cropRect = CGRect(x: 0, y: 0, width: cgImage.width, height: cropHeight)
        guard let cropped = cgImage.cropping(to: cropRect) else { return nil }
        // Sized from the pixels that were actually cut, not from the viewport.
        // `cropHeight` is clamped to the image, so a page shorter than its
        // viewport yields fewer rows than a full screenful — declaring the
        // result viewport-tall anyway stretched such a page vertically.
        return NSImage(
            cgImage: cropped,
            size: NSSize(width: CGFloat(cgImage.width) / scale, height: CGFloat(cropHeight) / scale)
        )
    }
}

struct ViewportFrameHeader: View {
    let viewport: APIClient.VisualViewportDTO
    // LocalizedStringKey, not String: Text(String) resolves to SwiftUI's
    // verbatim initializer and would skip the string catalog entirely.
    let trailing: LocalizedStringKey

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

    func viewportFrameIcon(_ name: String) -> String {
        switch name {
        case "desktop": "desktopcomputer"
        case "tablet": "ipad"
        case "mobile": "iphone"
        default: "rectangle"
        }
    }
}

struct LiveViewportWebView: NSViewRepresentable {
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

struct IssueMetricPill: View {
    let label: LocalizedStringKey
    let value: Int
    let color: Color

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
            Text("\(value)")
                .font(.caption.bold())
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .frame(minHeight: 34)
        .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 7))
    }
}

struct ResponsiveIssueRow: View {
    let issue: APIClient.VisualResponsiveIssueDTO

    private var severityColor: Color {
        switch issue.severity {
        case "high": .red
        case "medium": .orange
        default: .secondary
        }
    }

    private var localizedTitle: LocalizedStringKey {
        switch issue.kind {
        case "missing_viewport_meta": "Mobile viewport configuration is missing"
        case "horizontal_overflow": "Page overflows horizontally"
        case "offscreen_element": "Element extends beyond the viewport"
        case "clipped_content": "Content may be clipped"
        case "small_text": "Very small text"
        case "small_touch_target": "Small touch target"
        case "large_sticky_element": "Sticky element covers much of the viewport"
        case "overlapping_controls": "Interactive controls overlap"
        default: LocalizedStringKey(issue.title)
        }
    }

    private var localizedDetail: LocalizedStringKey {
        switch issue.kind {
        case "missing_viewport_meta": "Without a viewport meta tag, mobile browsers may render the page at a desktop-like width."
        case "horizontal_overflow": "The page is wider than the selected viewport and may require horizontal scrolling."
        case "offscreen_element": "Part of this element lies outside the visible page width."
        case "clipped_content": "The content is larger than its box while overflow is hidden."
        case "small_text": "This text may be difficult to read at the selected viewport."
        case "small_touch_target": "This control is smaller than the recommended 44x44 px touch area."
        case "large_sticky_element": "This fixed or sticky element occupies more than 30% of the viewport height."
        case "overlapping_controls": "Two interactive elements cover each other and may be difficult to use."
        default: LocalizedStringKey(issue.detail)
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if let evidenceURL = issue.evidenceURL {
                AsyncImage(url: APIClient.shared.visualSnapshotFileURL(path: evidenceURL)) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFill()
                    case .failure:
                        Color.secondary.opacity(0.08)
                            .overlay { Image(systemName: "photo").foregroundStyle(.secondary) }
                    default:
                        Color.secondary.opacity(0.08)
                            .overlay { ProgressView().scaleEffect(0.5) }
                    }
                }
                .frame(width: 92, height: 62)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.secondary.opacity(0.18)))
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Circle().fill(severityColor).frame(width: 7, height: 7)
                    Text(localizedTitle)
                        .font(.caption.bold())
                }
                Text(localizedDetail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    Text(issue.selectorHint)
                        .font(.caption2.monospaced())
                        .lineLimit(1)
                    if !issue.metric.isEmpty {
                        Text("·")
                            .foregroundStyle(.tertiary)
                        Text(issue.metric)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Button {
                        copy(issue.selectorHint)
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .buttonStyle(.borderless)
                    .help("Copy selector")
                }
            }
        }
        .padding(10)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))
    }
}
