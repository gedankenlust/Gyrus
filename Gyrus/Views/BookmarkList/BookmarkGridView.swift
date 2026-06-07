import SwiftUI
import AppKit

/// Collects each card's frame (in the grid coordinate space) so marquee
/// selection can hit-test which cards a dragged rectangle covers.
private struct CardFramesKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

struct BookmarkGridView: View {
    @Environment(BookmarkStore.self) private var bookmarkStore
    @Environment(UIStateStore.self) private var uiStateStore

    private let columns = [GridItem(.adaptive(minimum: 180, maximum: 240), spacing: 12)]
    private let gridSpace = "gridSpace"

    @State private var cardFrames: [String: CGRect] = [:]
    @State private var marqueeRect: CGRect? = nil
    /// Anchor for Shift-click range selection.
    @State private var anchorId: String? = nil

    var body: some View {
        ScrollView {
            ZStack(alignment: .topLeading) {
                // Background layer catches marquee drags and background taps in
                // empty space. It sits behind the cards, so a drag that starts
                // on a card still drags the card instead.
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture {
                        bookmarkStore.selectedIds.removeAll()
                        bookmarkStore.selectedBookmark = nil
                        anchorId = nil
                    }
                    .gesture(marqueeGesture)

                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(bookmarkStore.bookmarks) { bookmark in
                        card(bookmark)
                            .onAppear { prefetchIfNeeded(bookmark) }
                    }
                }
                .padding(12)

                // The selection rectangle while dragging.
                if let rect = marqueeRect {
                    Rectangle()
                        .fill(Color.accentColor.opacity(0.15))
                        .overlay(Rectangle().strokeBorder(Color.accentColor.opacity(0.7), lineWidth: 1))
                        .frame(width: rect.width, height: rect.height)
                        .offset(x: rect.minX, y: rect.minY)
                        .allowsHitTesting(false)
                }
            }
            .coordinateSpace(name: gridSpace)
            .onPreferenceChange(CardFramesKey.self) { cardFrames = $0 }

            // Infinite scroll sentinel
            if bookmarkStore.hasMore {
                HStack {
                    if bookmarkStore.isLoadingMore {
                        ProgressView().scaleEffect(0.7)
                        Text("Loading more…").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .onAppear {
                    Task { try? await bookmarkStore.loadMoreBookmarks() }
                }
            }
        }
        // Accept URLs dragged from a browser address bar
        .dropDestination(for: URL.self) { urls, _ in
            if let url = urls.first,
               (url.scheme == "https" || url.scheme == "http") {
                Task { try? await bookmarkStore.addBookmarkFromURL(url.absoluteString) }
                return true
            }
            return false
        }
    }

    @ViewBuilder
    private func card(_ bookmark: Bookmark) -> some View {
        BookmarkCardView(bookmark: bookmark)
            .background(
                GeometryReader { geo in
                    Color.clear.preference(
                        key: CardFramesKey.self,
                        value: [bookmark.id: geo.frame(in: .named(gridSpace))]
                    )
                }
            )
            .onTapGesture {
                handleTap(bookmark)
            }
            .contextMenu {
                BookmarkContextMenu(ids: selectionForAction(bookmark), bookmarks: bookmarkStore.bookmarks)
            }
            .draggable(dragPayload(for: bookmark)) {
                BookmarkCardView(bookmark: bookmark)
                    .environment(bookmarkStore)
                    .frame(width: 200)
                    .opacity(0.9)
            }
    }

    // MARK: - Selection

    private func handleTap(_ bookmark: Bookmark) {
        let flags = NSEvent.modifierFlags
        if flags.contains(.command) {
            // Toggle this card in/out of the selection.
            if bookmarkStore.selectedIds.contains(bookmark.id) {
                bookmarkStore.selectedIds.remove(bookmark.id)
            } else {
                bookmarkStore.selectedIds.insert(bookmark.id)
                bookmarkStore.selectedBookmark = bookmark
            }
            anchorId = bookmark.id
        } else if flags.contains(.shift), let anchor = anchorId,
                  let from = index(of: anchor), let to = index(of: bookmark.id) {
            // Select the contiguous range between the anchor and this card.
            let range = from <= to ? from...to : to...from
            bookmarkStore.selectedIds = Set(bookmarkStore.bookmarks[range].map(\.id))
            bookmarkStore.selectedBookmark = bookmark
        } else {
            bookmarkStore.selectedIds = [bookmark.id]
            bookmarkStore.selectedBookmark = bookmark
            anchorId = bookmark.id
        }
    }

    private func index(of id: String) -> Int? {
        bookmarkStore.bookmarks.firstIndex { $0.id == id }
    }

    private var marqueeGesture: some Gesture {
        DragGesture(minimumDistance: 6, coordinateSpace: .named(gridSpace))
            .onChanged { value in
                let rect = CGRect(
                    x: min(value.startLocation.x, value.location.x),
                    y: min(value.startLocation.y, value.location.y),
                    width: abs(value.location.x - value.startLocation.x),
                    height: abs(value.location.y - value.startLocation.y)
                )
                marqueeRect = rect
                let hits = cardFrames.filter { $0.value.intersects(rect) }.map(\.key)
                bookmarkStore.selectedIds = Set(hits)
            }
            .onEnded { _ in
                marqueeRect = nil
            }
    }

    /// IDs a context-menu action should apply to: the whole selection if the
    /// right-clicked card is part of it, otherwise just that card.
    private func selectionForAction(_ bookmark: Bookmark) -> Set<String> {
        if bookmarkStore.selectedIds.contains(bookmark.id), bookmarkStore.selectedIds.count > 1 {
            return bookmarkStore.selectedIds
        }
        return [bookmark.id]
    }

    /// How many items before the end to start fetching the next page, so the
    /// next chunk is ready before the user reaches the bottom (no visible spinner).
    private static let prefetchLead = 24

    private func prefetchIfNeeded(_ bookmark: Bookmark) {
        guard bookmarkStore.hasMore, !bookmarkStore.isLoadingMore else { return }
        let arr = bookmarkStore.bookmarks
        let triggerIndex = max(0, arr.count - Self.prefetchLead)
        guard triggerIndex < arr.count, arr[triggerIndex].id == bookmark.id else { return }
        Task { try? await bookmarkStore.loadMoreBookmarks() }
    }

    private func dragPayload(for bookmark: Bookmark) -> String {
        if bookmarkStore.selectedIds.contains(bookmark.id), bookmarkStore.selectedIds.count > 1 {
            return bookmarkStore.selectedIds.joined(separator: "\n")
        }
        return bookmark.id
    }
}
