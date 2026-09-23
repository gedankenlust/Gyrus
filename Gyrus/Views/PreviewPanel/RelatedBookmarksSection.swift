import SwiftUI

/// Up to five indexed neighbors of the open bookmark. Hidden when this page
/// has no embedding, so the overview stays quiet without semantic search.
struct RelatedBookmarksSection: View {
    let bookmarkId: String
    @Environment(BookmarkStore.self) private var bookmarkStore
    @State private var related: [Bookmark] = []

    var body: some View {
        Group {
            if !related.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Similar bookmarks")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ForEach(related) { item in
                        Button {
                            bookmarkStore.selectedBookmark = item
                            bookmarkStore.selectedIds = [item.id]
                        } label: {
                            Text(item.title.isEmpty ? item.url : item.title)
                                .font(.callout)
                                .foregroundStyle(.primary)
                                .lineLimit(2)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .task(id: bookmarkId) {
            related = (try? await APIClient.shared.relatedBookmarks(bookmarkId: bookmarkId)) ?? []
        }
    }
}
