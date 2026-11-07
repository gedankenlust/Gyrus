import Foundation
import Observation

/// The loaded bookmark rows of the current view, their selection and counts.
///
/// Split by responsibility across files:
///   BookmarkStore.swift           state, view loading, pagination, search, selection
///   BookmarkStore+Edits.swift     counts, local edits, CRUD, metadata, browser
///   BookmarkStore+Notes.swift     notes and their persisted drafts
/// Deleting, restoring and purging bookmarks lives in TrashController.
@MainActor
@Observable
final class BookmarkStore {
    var bookmarks: [Bookmark] = []
    var selectedBookmark: Bookmark? = nil
    var selectedIds: Set<String> = [] {
        didSet { if oldValue != selectedIds { selectionGeneration += 1 } }
    }
    private var selectionGeneration = 0
    private(set) var isFilteringSelection = false
    var sortBy: String = "created_at"
    var sortOrder: String = "desc"
    var hasMore: Bool = false
    var isLoadingMore: Bool = false
    private(set) var loadMoreError: String?
    var currentOffset: Int = 0
    var totalBookmarkCount: Int = 0
    var deadBookmarkCount: Int = 0
    var unreadBookmarkCount: Int = 0
    var trashCount: Int = 0
    /// When true the search bar uses the semantic (embedding) path instead of FTS.
    var semanticSearchEnabled: Bool = false
    /// Status from /api/search/status (checked once at startup).
    var semanticSearchAvailable: Bool = false
    var searchQuery: String = ""
    var usingKeywordFallback = false
    var noteDrafts: [String: String] = [:] { didSet { persistDrafts() } }
    var draftStorageError: String?
    var noteErrors: [String: String] = [:]
    var savingNoteIds: Set<String> = []

    /// IDs that are scheduled for deletion (within the Undo window)
    /// and should be hidden from the UI.
    var pendingDeletionIds: Set<String> = []

    let api: APIClient
    let draftStorage: NoteDraftStorage?
    /// Bumped when the library is replaced or reset, so a late result of the
    /// old library (a note save, a metadata fetch) is dropped.
    private(set) var libraryGeneration = 0
    /// The folder/tag/filter/search the loaded rows belong to.
    private(set) var loadContext = LoadContext.allBookmarks
    /// Bookmark IDs we've already tried to fetch metadata for this session, so
    /// scrolling a card in and out of view doesn't re-hit the network for a
    /// site whose favicon/metadata simply can't be fetched. Internal only for
    /// fetchMeta in BookmarkStore+Edits.swift.
    var metaAttempted: Set<String> = []

    private let pageSize = 100
    private var searchTask: Task<Void, Never>?
    private var loadGeneration = 0

    init(api: APIClient = .shared, draftStorage: NoteDraftStorage? = .applicationStorage) {
        self.api = api
        self.draftStorage = draftStorage
        do { self.noteDrafts = try draftStorage?.read() ?? [:] }
        catch { self.draftStorageError = String(localized: "Note drafts could not be loaded.") }
    }

    func resetLocalState() {
        libraryGeneration += 1
        loadGeneration += 1
        searchTask?.cancel()
        bookmarks = []
        selectedBookmark = nil
        selectedIds = []
        noteDrafts = [:]
        noteErrors = [:]
        savingNoteIds = []
        pendingDeletionIds = []
        metaAttempted = []
        searchQuery = ""
        semanticSearchEnabled = false
        semanticSearchAvailable = false
        usingKeywordFallback = false
        totalBookmarkCount = 0
        deadBookmarkCount = 0
        unreadBookmarkCount = 0
        trashCount = 0
        currentOffset = 0
        hasMore = false
        isLoadingMore = false
        loadMoreError = nil
    }

    struct LoadContext {
        let collectionId: String?
        let tagName: String?
        let showDeadOnly: Bool
        let unreadOnly: Bool
        let showTrash: Bool
        let query: String
        var semantic: Bool

        static let allBookmarks = LoadContext(
            collectionId: nil, tagName: nil, showDeadOnly: false,
            unreadOnly: false, showTrash: false, query: "", semantic: false
        )

        /// Same folder/tag/filter/search, ignoring the semantic fallback flag
        /// the fetch itself may flip.
        func showsSameView(as other: LoadContext) -> Bool {
            collectionId == other.collectionId && tagName == other.tagName
                && showDeadOnly == other.showDeadOnly && unreadOnly == other.unreadOnly
                && showTrash == other.showTrash && query == other.query
        }
    }

    // MARK: - Fetching

    func loadBookmarks(collectionId: String? = nil, tagName: String? = nil, showDeadOnly: Bool = false, unreadOnly: Bool = false, showTrash: Bool = false, query: String = "", refreshCount: Bool = true) async throws {
        let context = LoadContext(
            collectionId: collectionId,
            tagName: tagName,
            showDeadOnly: showDeadOnly,
            unreadOnly: unreadOnly,
            showTrash: showTrash,
            query: query, semantic: semanticSearchEnabled
        )
        let changesView = !context.showsSameView(as: loadContext)
        // A selection made in another view must never be acted on here: ⌘⌫ or
        // "Open" would hit bookmarks the user can no longer see. Clear it now
        // and keep only what the new view actually shows once it has loaded.
        let carriedSelection = changesView ? selectedIds : []
        let carriedBookmark = changesView ? selectedBookmark : nil
        if changesView {
            selectedIds = []
            selectedBookmark = nil
        }
        loadContext = context
        loadGeneration += 1
        let generation = loadGeneration
        searchQuery = query
        usingKeywordFallback = false
        currentOffset = 0
        hasMore = false
        isLoadingMore = false
        loadMoreError = nil
        let page: [Bookmark]
        do {
            page = try await fetchPage(
                offset: 0,
                collectionId: context.collectionId,
                tagName: context.tagName,
                showDeadOnly: context.showDeadOnly,
                unreadOnly: context.unreadOnly,
                showTrash: context.showTrash,
                query: context.query, semantic: context.semantic, generation: generation
            )
        } catch {
            // Rows of the previous view under the new sidebar selection would
            // let actions run on the wrong bookmarks. Show an empty list instead.
            if generation == loadGeneration, changesView, !error.isCancellation {
                bookmarks = []
            }
            throw error
        }
        guard generation == loadGeneration else { return }

        // Exclude pending deletions
        bookmarks = page.filter { !pendingDeletionIds.contains($0.id) }
        if changesView {
            let visible = Set(bookmarks.map(\.id))
            selectedIds = carriedSelection.intersection(visible)
            if let carried = carriedBookmark, visible.contains(carried.id) {
                selectedBookmark = bookmarks.first { $0.id == carried.id }
            }
        }

        currentOffset = page.count
        hasMore = page.count == pageSize

        if !refreshCount {
            return
        } else if context.showTrash {
            // In the Trash view the "total" shown is the trash count.
            let n = try await api.trashCount()
            if generation == loadGeneration {
                trashCount = n
            }
        } else {
            let total = try await api.bookmarkCount()
            if generation == loadGeneration {
                totalBookmarkCount = max(0, total - pendingDeletionIds.count)
            }
        }
    }

    /// Refetch the rows already loaded for the current view without resetting
    /// pagination. A background status refresh must not throw the user back to
    /// the first page and drop an in-flight "load more".
    func refreshLoadedRows() async throws {
        guard !isLoadingMore else { return }
        let context = loadContext
        let generation = loadGeneration
        let startOffset = currentOffset
        let target = max(startOffset, pageSize)
        var rows: [Bookmark] = []
        var offset = 0
        var lastPageCount = 0
        while offset < target {
            let page = try await fetchPage(
                offset: offset,
                collectionId: context.collectionId,
                tagName: context.tagName,
                showDeadOnly: context.showDeadOnly,
                unreadOnly: context.unreadOnly,
                showTrash: context.showTrash,
                query: context.query, semantic: context.semantic, generation: generation
            )
            guard generation == loadGeneration else { return }
            rows.append(contentsOf: page)
            lastPageCount = page.count
            offset += page.count
            if page.count < pageSize { break }
        }
        // A load-more that ran meanwhile already extended the list; keep it.
        guard generation == loadGeneration, !isLoadingMore, currentOffset == startOffset else { return }
        var seen = Set<String>()
        bookmarks = rows.filter { !pendingDeletionIds.contains($0.id) && seen.insert($0.id).inserted }
        currentOffset = offset
        hasMore = lastPageCount == pageSize
        if let selected = selectedBookmark,
           let fresh = bookmarks.first(where: { $0.id == selected.id }) {
            selectedBookmark = fresh
        }
    }

    /// Any visible item in the final window can trigger prefetch. Fast scrolling
    /// may skip the one exact row that previously owned this responsibility.
    func shouldPrefetch(near id: String) -> Bool {
        hasMore && !isLoadingMore && loadMoreError == nil
            && bookmarks.suffix(40).contains { $0.id == id }
    }

    func loadMoreBookmarks() async throws {
        guard hasMore && !isLoadingMore else { return }
        let context = loadContext
        let generation = loadGeneration
        isLoadingMore = true
        loadMoreError = nil
        defer {
            if generation == loadGeneration {
                isLoadingMore = false
            }
        }

        do {
            let page = try await fetchPage(
                offset: currentOffset,
                collectionId: context.collectionId,
                tagName: context.tagName,
                showDeadOnly: context.showDeadOnly,
                unreadOnly: context.unreadOnly,
                showTrash: context.showTrash,
                query: context.query, semantic: context.semantic, generation: generation
            )
            guard generation == loadGeneration else { return }

            // Exclude pending deletions
            let filtered = page.filter { !pendingDeletionIds.contains($0.id) }
            let existingIds = Set(bookmarks.map(\.id))
            bookmarks.append(contentsOf: filtered.filter { !existingIds.contains($0.id) })

            currentOffset += page.count
            hasMore = page.count == pageSize
        } catch {
            if generation == loadGeneration && !(error is CancellationError) {
                loadMoreError = String(localized: "More bookmarks could not be loaded. Please try again.")
            }
            throw error
        }
    }

    private func fetchPage(offset: Int, collectionId: String? = nil, tagName: String? = nil, showDeadOnly: Bool = false, unreadOnly: Bool = false, showTrash: Bool = false, query: String = "", semantic: Bool? = nil, generation: Int? = nil) async throws -> [Bookmark] {
        if showTrash {
            return try await api.trashedBookmarks(limit: pageSize, offset: offset)
        } else if !query.isEmpty && (semantic ?? loadContext.semantic) {
            // Degrade to keyword search when it returns nothing OR throws
            // (Ollama down only yields [], but network/server errors throw).
            let results = (try? await api.searchSemantic(
                query: query, limit: pageSize, offset: offset
            )) ?? []
            if results.isEmpty && offset == 0 {
                let keywordResults = try await api.search(query: query, limit: pageSize, offset: 0)
                if generation == nil || generation == loadGeneration {
                    usingKeywordFallback = true
                    loadContext.semantic = false
                }
                return keywordResults
            }
            return results
        } else if !query.isEmpty {
            return try await api.search(query: query, limit: pageSize, offset: offset)
        } else if showDeadOnly {
            return try await api.bookmarks(deadOnly: true, limit: pageSize, offset: offset, sortBy: sortBy, order: sortOrder)
        } else if unreadOnly {
            return try await api.bookmarks(unreadOnly: true, limit: pageSize, offset: offset, sortBy: sortBy, order: sortOrder)
        } else if let tag = tagName {
            return try await api.bookmarks(tag: tag, limit: pageSize, offset: offset, sortBy: sortBy, order: sortOrder)
        } else {
            return try await api.bookmarks(collectionId: collectionId, limit: pageSize, offset: offset, sortBy: sortBy, order: sortOrder)
        }
    }

    // MARK: - Selection

    /// Only adjust the selection that initiated the lookup, including unloaded rows.
    /// A navigation or selection change while awaiting the backend cancels the result.
    func deselectTaggedBookmarks() async throws -> Int? {
        guard !isFilteringSelection, !selectedIds.isEmpty else { return nil }
        isFilteringSelection = true
        defer { isFilteringSelection = false }
        let ids = selectedIds
        let selection = selectionGeneration
        let load = loadGeneration
        let library = libraryGeneration
        let tagged = try await api.taggedBookmarkIds(in: ids)
        guard selection == selectionGeneration, load == loadGeneration,
              library == libraryGeneration, !Task.isCancelled else { return nil }
        let removed = ids.intersection(tagged)
        selectedIds.subtract(removed)
        if let bookmark = selectedBookmark, removed.contains(bookmark.id) {
            selectedBookmark = nil
        }
        return removed.count
    }

    func selectAllInCurrentView(collectionId: String? = nil, tagName: String? = nil, showDeadOnly: Bool = false, unreadOnly: Bool = false, showTrash: Bool = false, query: String = "") async throws {
        let ids: [String]
        let generation = loadGeneration
        if showTrash || (!query.isEmpty && loadContext.semantic) {
            var allIds: [String] = []
            var offset = 0
            while true {
                let page = try await fetchPage(offset: offset, showTrash: showTrash, query: query, semantic: loadContext.semantic, generation: generation)
                guard generation == loadGeneration else { return }
                allIds.append(contentsOf: page.map(\.id))
                if page.count < pageSize { break }
                offset += page.count
            }
            ids = allIds
        } else if !query.isEmpty {
            ids = try await api.bookmarkIds(query: query)
        } else if showDeadOnly {
            ids = try await api.bookmarkIds(deadOnly: true)
        } else if unreadOnly {
            ids = try await api.bookmarkIds(unreadOnly: true)
        } else if let tag = tagName {
            ids = try await api.bookmarkIds(tag: tag)
        } else {
            ids = try await api.bookmarkIds(collectionId: collectionId)
        }
        // Exclude pending deletions from selection too
        guard generation == loadGeneration else { return }
        selectedIds = Set(ids).subtracting(pendingDeletionIds)
    }

    // MARK: - Search

    /// Debounce typing; `onSearch` reloads the current view with the new query.
    func scheduleSearch(_ query: String, onSearch: @escaping () async -> Void) {
        searchTask?.cancel()
        searchQuery = query
        usingKeywordFallback = false
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            await onSearch()
        }
    }
}
