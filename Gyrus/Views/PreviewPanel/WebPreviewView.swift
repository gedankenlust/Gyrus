import SwiftUI
import WebKit

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
        let wv = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        wv.navigationDelegate = context.coordinator
        controller.webView = wv
        wv.load(URLRequest(url: url))
        return wv
    }

    func updateNSView(_ wv: WKWebView, context: Context) {
        guard wv.url?.absoluteString != url.absoluteString else { return }
        wv.load(URLRequest(url: url))
    }

    func makeCoordinator() -> Coordinator { Coordinator(controller) }

    final class Coordinator: NSObject, WKNavigationDelegate {
        let ctrl: WebController
        init(_ c: WebController) { ctrl = c }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation _: WKNavigation!) {
            ctrl.isLoading = true
        }
        func webView(_ webView: WKWebView, didFinish _: WKNavigation!) {
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
