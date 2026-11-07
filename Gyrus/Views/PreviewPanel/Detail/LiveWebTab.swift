import SwiftUI

/// Page → Live: the site itself in a sandboxed web view. Navigation buttons
/// sit in the header's control row; this view only adds the failure state.
struct LiveWebTab: View {
    let bookmark: Bookmark
    let controller: WebController

    var body: some View {
        if let url = URL(string: bookmark.url) {
            WebPreviewView(url: url, controller: controller)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // Overlay rather than replace: the web view must stay alive
                // so Try Again, Back and a new bookmark's URL can reuse it.
                .overlay {
                    if let error = controller.loadError {
                        WebLoadErrorView(error: error, url: bookmark.url, controller: controller)
                    }
                }
        } else {
            ContentUnavailableView {
                Label("Page can't be shown", systemImage: "exclamationmark.triangle")
            } description: {
                Text("This bookmark's address is not a valid web address.")
            }
        }
    }
}

/// Shown instead of a blank pane when the page fails to load (offline, DNS,
/// TLS, blocked scheme).
private struct WebLoadErrorView: View {
    let error: WebLoadError
    let url: String
    let controller: WebController

    var body: some View {
        ContentUnavailableView {
            Label("Page can't be shown", systemImage: "exclamationmark.triangle")
        } description: {
            Text(error.message)
        } actions: {
            if error.isRetryable {
                Button("Try Again") { controller.retry() }
            }
            OpenInBrowserButton(url: url)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
    }
}
