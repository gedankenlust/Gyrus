import SwiftUI
import AppKit
import WebKit

struct DesignSectionButton: View {
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
        .help(Text(section.title))
    }
}

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

        do {
            let url = APIClient.shared.visualSnapshotFileURL(path: viewport.screenshotURL)
            let (data, _) = try await URLSession.shared.data(from: url)
            guard let source = NSImage(data: data) else { return }
            image = cropViewport(from: source, viewport: viewport) ?? source
        } catch {
            image = nil
        }
    }

    func cropViewport(from source: NSImage, viewport: APIClient.VisualViewportDTO) -> NSImage? {
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

struct ViewportFrameHeader: View {
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
