import SwiftUI
import WebKit

enum WebPreviewSecurityPolicy {
    static func configuration() -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        return configuration
    }

    static func allowsNavigation(
        to target: URL,
        from initialURL: URL,
        isMainFrame: Bool
    ) -> Bool {
        let scheme = target.scheme?.lowercased()
        if !isMainFrame, ["about", "blob", "data"].contains(scheme) {
            return true
        }
        guard ["http", "https"].contains(scheme), let targetHost = target.host else {
            return false
        }
        guard isPrivateHost(targetHost) else { return true }
        guard let initialHost = initialURL.host, isPrivateHost(initialHost) else { return false }
        return normalizedHost(targetHost) == normalizedHost(initialHost)
    }

    static func isPrivateHost(_ value: String) -> Bool {
        let host = normalizedHost(value)
        if host == "localhost" || host.hasSuffix(".local") || !host.contains(".") {
            return true
        }
        if host == "::" || host == "::1" {
            return true
        }
        if host.hasPrefix("::ffff:") {
            return isPrivateHost(String(host.dropFirst("::ffff:".count)))
        }
        if host.contains(":") {
            return host.hasPrefix("fc")
                || host.hasPrefix("fd")
                || ["fe8", "fe9", "fea", "feb", "ff"].contains(where: host.hasPrefix)
        }
        let parts = host.split(separator: ".")
        if parts.contains(where: { $0.count > 1 && $0.first == "0" }) {
            return true
        }
        let octets = parts.compactMap { Int($0) }
        guard octets.count == 4, octets.allSatisfy({ (0...255).contains($0) }) else {
            return false
        }
        return octets[0] == 10
            || octets[0] == 127
            || (octets[0] == 169 && octets[1] == 254)
            || (octets[0] == 172 && (16...31).contains(octets[1]))
            || (octets[0] == 192 && octets[1] == 168)
            || octets[0] == 0
    }

    private static func normalizedHost(_ value: String) -> String {
        value.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".[]"))
    }
}

// MARK: - WebController

/// Why the live preview has nothing to show. `isRetryable` is false when our
/// own navigation policy refused the page, since retrying cannot help there.
struct WebLoadError: Equatable {
    let message: String
    let failingURL: URL?
    let isRetryable: Bool
}

@Observable
final class WebController {
    // Not observed: set while SwiftUI builds/updates the NSView, where
    // publishing a change would be "modifying state during view update".
    @ObservationIgnored weak var webView: WKWebView?
    @ObservationIgnored var requestedURL: URL?
    var isLoading = false
    var canGoBack = false
    var canGoForward = false
    var loadError: WebLoadError?

    func goBack()    { webView?.goBack() }
    func goForward() { webView?.goForward() }
    func reload()    { webView?.reload() }
    func stop()      { webView?.stopLoading() }

    /// Load the page that failed again. `reload()` is not enough: after a
    /// failed first load the web view has no URL of its own to reload.
    func retry() {
        let target = loadError?.failingURL ?? requestedURL
        loadError = nil
        guard let webView, let target else { return }
        webView.load(URLRequest(url: target))
    }
}

// MARK: - WebPreviewView

struct WebPreviewView: NSViewRepresentable {
    let url: URL
    let controller: WebController

    func makeNSView(context: Context) -> WKWebView {
        let wv = WKWebView(frame: .zero, configuration: WebPreviewSecurityPolicy.configuration())
        wv.navigationDelegate = context.coordinator
        controller.webView = wv
        controller.requestedURL = url
        wv.load(URLRequest(url: url))
        return wv
    }

    func updateNSView(_ wv: WKWebView, context: Context) {
        guard wv.url?.absoluteString != url.absoluteString,
              controller.requestedURL?.absoluteString != url.absoluteString else { return }
        context.coordinator.currentURL = url
        context.coordinator.hasCommittedPage = false
        controller.requestedURL = url
        wv.load(URLRequest(url: url))
    }

    func makeCoordinator() -> Coordinator { Coordinator(controller, initialURL: url) }

    final class Coordinator: NSObject, WKNavigationDelegate {
        let ctrl: WebController
        var currentURL: URL
        /// Whether the web view shows a page for the current bookmark yet.
        /// A refused navigation before that would otherwise leave a blank
        /// (or the previous bookmark's) page with no explanation.
        var hasCommittedPage = false

        init(_ c: WebController, initialURL: URL) {
            ctrl = c
            currentURL = initialURL
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            guard let target = navigationAction.request.url else {
                decisionHandler(.cancel)
                return
            }
            let isMainFrame = navigationAction.targetFrame?.isMainFrame ?? true
            let allowed = WebPreviewSecurityPolicy.allowsNavigation(
                to: target,
                from: currentURL,
                isMainFrame: isMainFrame
            )
            if !allowed, isMainFrame, !hasCommittedPage {
                ctrl.loadError = WebLoadError(
                    message: String(localized: "This page can't be shown in the preview. Open it in your browser instead."),
                    failingURL: target,
                    isRetryable: false
                )
            }
            decisionHandler(allowed ? .allow : .cancel)
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation _: WKNavigation!) {
            ctrl.isLoading = true
            ctrl.loadError = nil
        }
        func webView(_ webView: WKWebView, didCommit _: WKNavigation!) {
            hasCommittedPage = true
        }
        func webView(_ webView: WKWebView, didFinish _: WKNavigation!) {
            if let url = webView.url {
                currentURL = url
            }
            ctrl.isLoading = false
            ctrl.canGoBack    = webView.canGoBack
            ctrl.canGoForward = webView.canGoForward
        }
        // After commit the page is (partly) visible, so a late failure only
        // stops the spinner instead of covering the content.
        func webView(_ webView: WKWebView, didFail _: WKNavigation!, withError _: Error) {
            ctrl.isLoading = false
            ctrl.canGoBack    = webView.canGoBack
            ctrl.canGoForward = webView.canGoForward
        }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation _: WKNavigation!, withError error: Error) {
            ctrl.isLoading = false
            ctrl.canGoBack    = webView.canGoBack
            ctrl.canGoForward = webView.canGoForward
            guard Self.isUserVisible(error) else { return }
            let nsError = error as NSError
            ctrl.loadError = WebLoadError(
                message: nsError.localizedDescription,
                failingURL: nsError.userInfo[NSURLErrorFailingURLErrorKey] as? URL,
                isRetryable: true
            )
        }

        /// Cancellations are not failures: they come from Stop, from a new
        /// navigation replacing the old one, and from our own policy refusing
        /// a link (WebKit error 102), which must not cover the current page.
        private static func isUserVisible(_ error: Error) -> Bool {
            let nsError = error as NSError
            if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorCancelled { return false }
            // 102: frame load interrupted by policy change; 204: plug-in handles the load.
            if nsError.domain == "WebKitErrorDomain", [102, 204].contains(nsError.code) { return false }
            return true
        }
    }
}
