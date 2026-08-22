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

@Observable
final class WebController {
    weak var webView: WKWebView?
    var isLoading = false
    var canGoBack = false
    var canGoForward = false

    func goBack()    { webView?.goBack() }
    func goForward() { webView?.goForward() }
    func reload()    { webView?.reload() }
    func stop()      { webView?.stopLoading() }
}

// MARK: - WebPreviewView

struct WebPreviewView: NSViewRepresentable {
    let url: URL
    let controller: WebController

    func makeNSView(context: Context) -> WKWebView {
        let wv = WKWebView(frame: .zero, configuration: WebPreviewSecurityPolicy.configuration())
        wv.navigationDelegate = context.coordinator
        controller.webView = wv
        wv.load(URLRequest(url: url))
        return wv
    }

    func updateNSView(_ wv: WKWebView, context: Context) {
        guard wv.url?.absoluteString != url.absoluteString else { return }
        context.coordinator.currentURL = url
        wv.load(URLRequest(url: url))
    }

    func makeCoordinator() -> Coordinator { Coordinator(controller, initialURL: url) }

    final class Coordinator: NSObject, WKNavigationDelegate {
        let ctrl: WebController
        var currentURL: URL

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
            decisionHandler(
                WebPreviewSecurityPolicy.allowsNavigation(
                    to: target,
                    from: currentURL,
                    isMainFrame: isMainFrame
                ) ? .allow : .cancel
            )
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation _: WKNavigation!) {
            ctrl.isLoading = true
        }
        func webView(_ webView: WKWebView, didFinish _: WKNavigation!) {
            if let url = webView.url {
                currentURL = url
            }
            ctrl.isLoading = false
            ctrl.canGoBack    = webView.canGoBack
            ctrl.canGoForward = webView.canGoForward
        }
        func webView(_ webView: WKWebView, didFail _: WKNavigation!, withError _: Error) {
            ctrl.isLoading = false
        }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation _: WKNavigation!, withError _: Error) {
            ctrl.isLoading = false
        }
    }
}
