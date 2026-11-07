import SwiftUI
import AppKit
import WebKit

/// Text that comes from the inspected page or from backend detection.
///
/// `LocalizedStringKey(String)` parses Markdown, so a page could put a
/// clickable `[label](file:///…)` link into the inspector. Known backend terms
/// are still looked up in the string catalog, but nothing is interpreted.
func pageText(_ value: String, localize: Bool = false) -> Text {
    guard localize else { return Text(verbatim: value) }
    return Text(verbatim: Bundle.main.localizedString(forKey: value, value: value, table: nil))
}

struct SnapshotSection<Content: View>: View {
    let title: Text
    let icon: String
    let content: Content

    init(title: LocalizedStringKey, icon: String, @ViewBuilder content: () -> Content) {
        self.title = Text(title)
        self.icon = icon
        self.content = content()
    }

    /// For titles taken from the page itself (navigation labels).
    init(verbatimTitle: String, icon: String, @ViewBuilder content: () -> Content) {
        self.title = Text(verbatim: verbatimTitle)
        self.icon = icon
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label { title } icon: { Image(systemName: icon) }
                .font(.caption.bold())
                .foregroundStyle(.secondary)
            content
        }
    }
}

struct SnapshotViewportFrame: View {
    let viewport: APIClient.VisualViewportDTO

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ViewportFrameHeader(viewport: viewport, trailing: "Snapshot")

            ViewportPreviewBox(maximum: reviewPreviewSize(for: viewport)) { size in
                ViewportScreenshotImage(viewport: viewport)
                    .frame(width: size.width, height: size.height)
                    .background(.white)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

struct LiveViewportFrame: View {
    let url: URL?
    let viewport: APIClient.VisualViewportDTO

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ViewportFrameHeader(viewport: viewport, trailing: "Live")

            if let url {
                ViewportPreviewBox(maximum: reviewPreviewSize(for: viewport)) { size in
                    // Laid out at the real viewport size and scaled down, so the
                    // page sees the breakpoint it was captured at.
                    LiveViewportWebView(url: url, viewport: viewport)
                        .frame(width: CGFloat(viewport.width), height: CGFloat(viewport.height))
                        .scaleEffect(size.width / CGFloat(max(viewport.width, 1)), anchor: .topLeading)
                }
            } else {
                Text("Invalid URL.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

/// A frame in the viewport's proportions: `maximum` where the inspector has
/// the room, narrower where it does not.
///
/// The desktop preview used to be a fixed 620 points wide. A fixed width is a
/// minimum width, so the inspector column grew whenever the overview was open
/// and shrank again in every other section.
struct ViewportPreviewBox<Content: View>: View {
    let maximum: CGSize
    @ViewBuilder let content: (CGSize) -> Content

    var body: some View {
        Color.clear
            .aspectRatio(maximum.width / max(maximum.height, 1), contentMode: .fit)
            .frame(maxWidth: maximum.width)
            .overlay(alignment: .topLeading) {
                GeometryReader { proxy in
                    content(proxy.size)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(.secondary.opacity(0.25), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
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

    /// At most a common width rather than a common scale: at a shared scale the mobile
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

    /// Frames share the panel's width up to `cellWidth` each. A horizontal
    /// scroll view without indicators cut the last frame off at the panel
    /// edge with nothing saying more was there.
    private var comparisonRow: some View {
        HStack(alignment: .top, spacing: 12) {
            ForEach(viewports, id: \.name) { viewport in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 5) {
                        Image(systemName: designViewportIcon(viewport.name))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text(verbatim: viewport.name.capitalized)
                            .font(.caption.weight(.semibold))
                            .lineLimit(1)
                    }

                    ViewportScreenshotImage(viewport: viewport)
                        .aspectRatio(
                            CGFloat(max(viewport.width, 1)) / CGFloat(max(viewport.height, 1)),
                            contentMode: .fit
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
                        .lineLimit(1)
                }
                .frame(maxWidth: cellWidth, alignment: .leading)
            }
        }
        .padding(.vertical, 2)
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
        // `.task(id:)` cancels the previous load when the viewport changes. A
        // guard on `isLoading` here used to drop the new load instead, and the
        // old one then put the previous viewport's image on screen.
        let path = viewport.screenshotURL
        isLoading = true
        defer { if !Task.isCancelled { isLoading = false } }

        // Through the shared store: the comparison strip shows every viewport at
        // once, and the component thumbnails cut out of the same screenshots,
        // so each image should be fetched and decoded once.
        let source = await SnapshotImageStore.shared.image(atPath: path)
        guard !Task.isCancelled, path == viewport.screenshotURL else { return }
        guard let source else {
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
            Image(systemName: designViewportIcon(viewport.name))
                .foregroundStyle(.secondary)
            Text("\(viewport.name.capitalized) \(viewport.width)x\(viewport.height)")
                .font(.caption.bold())
            Spacer()
            Text(trailing)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

struct LiveViewportWebView: NSViewRepresentable {
    let url: URL
    let viewport: APIClient.VisualViewportDTO

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WebPreviewSecurityPolicy.configuration()
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

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        var currentURL: URL

        init(url: URL) {
            currentURL = url
        }

        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            currentURL = webView.url ?? currentURL
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
        ) {
            guard let target = navigationAction.request.url else {
                decisionHandler(.cancel)
                return
            }
            let isMainFrame = navigationAction.targetFrame?.isMainFrame ?? true
            decisionHandler(
                WebPreviewSecurityPolicy.allowsNavigation(
                    to: target,
                    from: currentURL,
                    isMainFrame: isMainFrame
                ) ? .allow : .cancel
            )
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

    private var localizedTitle: Text { Text(verbatim: issue.localizedTitle) }

    private var localizedDetail: Text {
        switch issue.kind {
        case "missing_viewport_meta": Text("Without a viewport meta tag, mobile browsers may render the page at a desktop-like width.")
        case "horizontal_overflow": Text("The page is wider than the selected viewport and may require horizontal scrolling.")
        case "offscreen_element": Text("Part of this element lies outside the visible page width.")
        case "clipped_content": Text("The content is larger than its box while overflow is hidden.")
        case "small_text": Text("This text may be difficult to read at the selected viewport.")
        case "small_touch_target": Text("This control is smaller than the recommended 44x44 px touch area.")
        case "large_sticky_element": Text("This fixed or sticky element occupies more than 30% of the viewport height.")
        case "overlapping_controls": Text("Two interactive elements cover each other and may be difficult to use.")
        default: pageText(issue.detail, localize: true)
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
                    localizedTitle
                        .font(.caption.bold())
                }
                localizedDetail
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
