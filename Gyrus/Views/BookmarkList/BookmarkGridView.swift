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

/// Width the grid's columns are laid out in, for arrow-key row navigation.
private struct GridWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

struct BookmarkGridView: View {
    @Environment(BookmarkStore.self) private var bookmarkStore
    @Environment(UIStateStore.self) private var uiStateStore
    @Environment(CollectionStore.self) private var collectionStore

    private static let minCardWidth: CGFloat = 180
    private static let cardSpacing: CGFloat = 12
    private let columns = [GridItem(.adaptive(minimum: BookmarkGridView.minCardWidth, maximum: 240),
                                    spacing: BookmarkGridView.cardSpacing)]
    private let gridSpace = "gridSpace"

    @State private var cardFrames: [String: CGRect] = [:]
    @State private var marqueeRect: CGRect? = nil
    /// Anchor for Shift-click / Shift-arrow range selection.
    @State private var anchorId: String? = nil
    /// The card arrow keys move from (the last clicked or arrowed-to card).
    @State private var cursorId: String? = nil
    @State private var gridWidth: CGFloat = 0
    @FocusState private var isGridFocused: Bool

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                ZStack(alignment: .topLeading) {
                    // Background layer catches marquee drags and background taps in
                    // empty space. It sits behind the cards, so a drag that starts
                    // on a card still drags the card instead.
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture {
                            isGridFocused = true
                            bookmarkStore.selectedIds.removeAll()
                            bookmarkStore.selectedBookmark = nil
                            anchorId = nil
                        }
                        .gesture(marqueeGesture)

                    LazyVGrid(columns: columns, spacing: Self.cardSpacing) {
                        ForEach(bookmarkStore.bookmarks) { bookmark in
                            card(bookmark)
                                .id(bookmark.id)
                                .onAppear { prefetchIfNeeded(bookmark) }
                        }
                    }
                    .background(
                        GeometryReader { geo in
                            Color.clear.preference(key: GridWidthKey.self, value: geo.size.width)
                        }
                    )
                    .padding(12)
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel(Text("Bookmarks"))

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
                .onPreferenceChange(GridWidthKey.self) { gridWidth = $0 }

                // Infinite scroll sentinel
                if bookmarkStore.hasMore {
                    LoadingMoreRow(loadsOnAppear: true)
                        .padding(.bottom, 4)
                }
            }
            // The grid itself takes keyboard focus: arrows move the selection,
            // Return opens it. Library-wide shortcuts (⌘A, ⌘⌫, ⌘O, Esc) stay
            // menu items in AppCommands. The ring around the whole scroll view
            // would add nothing — the selected card already shows where focus is.
            .focusable()
            .focusEffectDisabled()
            .focused($isGridFocused)
            .onMoveCommand { direction in
                moveSelection(direction, proxy: proxy)
            }
            .onKeyPress(.return) {
                guard !bookmarkStore.selectedIds.isEmpty else { return .ignored }
                AppStore.shared.requestOpenInBrowser(ids: bookmarkStore.selectedIds)
                return .handled
            }
        }
        // Accept URLs dragged from a browser address bar
        .dropDestination(for: URL.self) { urls, _ in
            if let url = urls.first,
               (url.scheme == "https" || url.scheme == "http") {
                Task {
                    do {
                        _ = try await bookmarkStore.addBookmarkFromURL(url.absoluteString, collectionId: collectionStore.selectedCollectionId)
                        AppStore.shared.uiStateStore.showInfo(String(localized: "Bookmark added."))
                    } catch APIError.duplicate {
                        AppStore.shared.uiStateStore.showInfo(String(localized: "Already saved."))
                    } catch {
                        AppStore.shared.uiStateStore.showError(error.localizedDescription)
                    }
                }
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
            // Simultaneous, so a single click still selects immediately
            // instead of waiting out the double-click interval.
            .simultaneousGesture(
                TapGesture(count: 2).onEnded { open(selectionForAction(bookmark)) }
            )
            .accessibilityAction {
                isGridFocused = true
                select(bookmark)
            }
            .accessibilityAction(named: Text("Open")) {
                open(selectionForAction(bookmark))
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
        isGridFocused = true
        // The second click of a double-click opens (see the simultaneous
        // gesture); re-running the selection logic would undo a ⌘-toggle.
        if let event = NSApp.currentEvent, event.clickCount > 1 { return }
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
            cursorId = bookmark.id
        } else if flags.contains(.shift), let anchor = anchorId,
                  let from = index(of: anchor), let to = index(of: bookmark.id) {
            // Select the contiguous range between the anchor and this card.
            let range = from <= to ? from...to : to...from
            bookmarkStore.selectedIds = Set(bookmarkStore.bookmarks[range].map(\.id))
            bookmarkStore.selectedBookmark = bookmark
            cursorId = bookmark.id
        } else {
            select(bookmark)
        }
    }

    /// Plain selection: exactly this card, which also becomes the anchor and
    /// the keyboard cursor.
    private func select(_ bookmark: Bookmark) {
        bookmarkStore.selectedIds = [bookmark.id]
        bookmarkStore.selectedBookmark = bookmark
        anchorId = bookmark.id
        cursorId = bookmark.id
    }

    private func open(_ ids: Set<String>) {
        guard !ids.isEmpty else { return }
        AppStore.shared.requestOpenInBrowser(ids: ids)
    }

    // MARK: - Keyboard navigation

    /// Columns the adaptive grid currently lays out: as many minimum-width
    /// cards as fit, with spacing between them (how `.adaptive` computes it).
    private var columnCount: Int {
        guard gridWidth > 0 else { return 1 }
        return max(1, Int((gridWidth + Self.cardSpacing) / (Self.minCardWidth + Self.cardSpacing)))
    }

    /// The card the arrow keys move from, if it is still selected.
    private var cursorIndex: Int? {
        if let cursorId, bookmarkStore.selectedIds.contains(cursorId), let i = index(of: cursorId) {
            return i
        }
        if let id = bookmarkStore.selectedBookmark?.id, bookmarkStore.selectedIds.contains(id) {
            return index(of: id)
        }
        return nil
    }

    /// Left/right step to the previous/next card, up/down to the same column
    /// one row away. Shift extends the selection from the anchor.
    private func moveSelection(_ direction: MoveCommandDirection, proxy: ScrollViewProxy) {
        let items = bookmarkStore.bookmarks
        guard !items.isEmpty else { return }
        let target: Int
        if let current = cursorIndex {
            let columns = columnCount
            switch direction {
            case .left: target = max(0, current - 1)
            case .right: target = min(items.count - 1, current + 1)
            case .up: target = current - columns >= 0 ? current - columns : current
            case .down:
                // From the second-to-last row, a short last row still takes
                // you to its final card (as in Finder).
                let lastRow = (items.count - 1) / columns
                target = current / columns < lastRow ? min(items.count - 1, current + columns) : current
            @unknown default: return
            }
        } else {
            target = 0
        }

        let bookmark = items[target]
        if NSEvent.modifierFlags.contains(.shift),
           let anchor = anchorId ?? cursorId, let from = index(of: anchor) {
            let range = from <= target ? from...target : target...from
            bookmarkStore.selectedIds = Set(items[range].map(\.id))
            bookmarkStore.selectedBookmark = bookmark
            anchorId = anchor
            cursorId = bookmark.id
        } else {
            select(bookmark)
        }
        proxy.scrollTo(bookmark.id)
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

    private func prefetchIfNeeded(_ bookmark: Bookmark) {
        guard bookmarkStore.shouldPrefetch(near: bookmark.id) else { return }
        Task { try? await bookmarkStore.loadMoreBookmarks() }
    }

    private func dragPayload(for bookmark: Bookmark) -> String {
        if bookmarkStore.selectedIds.contains(bookmark.id), bookmarkStore.selectedIds.count > 1 {
            return bookmarkStore.selectedIds.joined(separator: "\n")
        }
        return bookmark.id
    }
}
