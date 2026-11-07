import SwiftUI

/// The row under a paged bookmark list: a small spinner while the next page
/// loads, or the load error with a retry button.
///
/// With `loadsOnAppear` it also works as the infinite-scroll sentinel: the
/// grid keeps it at the end of its content while more pages exist, and
/// scrolling it into view requests the next page.
struct LoadingMoreRow: View {
    @Environment(BookmarkStore.self) private var bookmarkStore
    var loadsOnAppear = false

    var body: some View {
        HStack(spacing: 8) {
            if let error = bookmarkStore.loadMoreError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Button("Retry loading") { loadMore() }
                    .controlSize(.small)
            } else if bookmarkStore.isLoadingMore {
                ProgressView()
                    .controlSize(.small)
                Text("Loading more…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .accessibilityElement(children: .contain)
        .onAppear {
            guard loadsOnAppear, bookmarkStore.loadMoreError == nil else { return }
            loadMore()
        }
    }

    private func loadMore() {
        Task { try? await bookmarkStore.loadMoreBookmarks() }
    }
}
