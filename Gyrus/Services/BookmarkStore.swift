import Foundation
import Observation
import AppKit

@MainActor
@Observable
final class BookmarkStore {
    var bookmarks: [Bookmark] = []
    var selectedBookmark: Bookmark? = nil
    var selectedIds: Set<String> = []
    var sortBy: String = "created_at"
    var sortOrder: String = "desc"
    var hasMore: Bool = false
    var isLoadingMore: Bool = false
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

    /// IDs that are scheduled for deletion (within the Undo window) 
    /// and should be hidden from the UI.
    var pendingDeletionIds: Set<String> = []

    private let pageSize = 100
    private let api = APIClient.shared
    private var searchTask: Task<Void, Never>?

    /// Bookmark IDs we've already tried to fetch metadata for this session, so
    /// scrolling a card in and out of view doesn't re-hit the network for a
    /// site whose favicon/metadata simply can't be fetched.
    private var metaAttempted: Set<String> = []

    // MARK: - Fetching

    func loadBookmarks(collectionId: String? = nil, tagName: String? = nil, showDeadOnly: Bool = false, unreadOnly: Bool = false, showTrash: Bool = false, query: String = "") async throws {
        searchQuery = query
        currentOffset = 0
        let page = try await fetchPage(offset: 0, collectionId: collectionId, tagName: tagName, showDeadOnly: showDeadOnly, unreadOnly: unreadOnly, showTrash: showTrash, query: query)

        // Exclude pending deletions
        bookmarks = page.filter { !pendingDeletionIds.contains($0.id) }

        currentOffset = page.count
        hasMore = page.count == pageSize

        if showTrash {
            // In the Trash view the "total" shown is the trash count.
            let n = try await api.trashCount()
            trashCount = n
        } else {
            let total = try await api.bookmarkCount()
            totalBookmarkCount = max(0, total - pendingDeletionIds.count)
        }
    }

    func loadMoreBookmarks(collectionId: String? = nil, tagName: String? = nil, showDeadOnly: Bool = false, unreadOnly: Bool = false, showTrash: Bool = false, query: String = "") async throws {
        guard hasMore && !isLoadingMore else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }

        do {
            let page = try await fetchPage(offset: currentOffset, collectionId: collectionId, tagName: tagName, showDeadOnly: showDeadOnly, unreadOnly: unreadOnly, showTrash: showTrash, query: query)

            // Exclude pending deletions
            let filtered = page.filter { !pendingDeletionIds.contains($0.id) }
            bookmarks.append(contentsOf: filtered)

            currentOffset += page.count
            hasMore = page.count == pageSize
        } catch {
            hasMore = false
            throw error
        }
    }

    func fetchPage(offset: Int, collectionId: String? = nil, tagName: String? = nil, showDeadOnly: Bool = false, unreadOnly: Bool = false, showTrash: Bool = false, query: String = "") async throws -> [Bookmark] {
        if showTrash {
            return try await api.trashedBookmarks(limit: pageSize, offset: offset)
        } else if !query.isEmpty && semanticSearchEnabled {
            // Semantic search doesn't support pagination — always returns the full ranked list.
            // Degrade to keyword search when it returns nothing OR throws
            // (Ollama down only yields [], but network/server errors throw).
            let results = (try? await api.searchSemantic(query: query, limit: pageSize)) ?? []
            return results.isEmpty ? try await api.search(query: query, limit: pageSize, offset: offset) : results
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

    func selectAllInCurrentView(collectionId: String? = nil, tagName: String? = nil, showDeadOnly: Bool = false, unreadOnly: Bool = false, showTrash: Bool = false, query: String = "") async throws {
        let ids: [String]
        if showTrash {
            // The Trash list is already fully loaded into `bookmarks` for typical sizes.
            ids = bookmarks.map { $0.id }
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
        selectedIds = Set(ids).subtracting(pendingDeletionIds)
    }

    // MARK: - Read / Unread

    /// Toggle (or set) the read state and update local copies immediately.
    func setRead(_ bookmark: Bookmark, isRead: Bool) async throws {
        var update = BookmarkUpdate()
        update.isRead = isRead
        let updated = try await api.updateBookmark(id: bookmark.id, body: update)
        if let idx = bookmarks.firstIndex(where: { $0.id == bookmark.id }) { bookmarks[idx] = updated }
        if selectedBookmark?.id == bookmark.id { selectedBookmark = updated }
    }

    func setRead(ids: Set<String>, isRead: Bool) async throws {
        for id in ids {
            var update = BookmarkUpdate()
            update.isRead = isRead
            let updated = try await api.updateBookmark(id: id, body: update)
            if let idx = bookmarks.firstIndex(where: { $0.id == id }) { bookmarks[idx] = updated }
            if selectedBookmark?.id == id { selectedBookmark = updated }
        }
    }

    // MARK: - Trash

    /// Restore bookmarks from the Trash; drop them from the current (trash) list.
    func restoreFromTrash(ids: Set<String>) async throws {
        _ = try await api.restoreFromTrash(ids: Array(ids))
        bookmarks.removeAll { ids.contains($0.id) }
        selectedIds.subtract(ids)
        if let sel = selectedBookmark, ids.contains(sel.id) { selectedBookmark = nil }
        trashCount = max(0, trashCount - ids.count)
    }

    /// Permanently delete trashed bookmarks (nil = empty the whole Trash).
    func purgeTrash(ids: Set<String>?) async throws {
        _ = try await api.purgeTrash(ids: ids.map(Array.init))
        if let ids {
            bookmarks.removeAll { ids.contains($0.id) }
            selectedIds.subtract(ids)
            if let sel = selectedBookmark, ids.contains(sel.id) { selectedBookmark = nil }
            trashCount = max(0, trashCount - ids.count)
        } else {
            bookmarks.removeAll()
            selectedIds.removeAll()
            selectedBookmark = nil
            trashCount = 0
        }
    }

    // MARK: - CRUD

    func deleteBookmark(_ bookmark: Bookmark) -> (removed: [(bookmark: Bookmark, index: Int)], deleteIds: Set<String>) {
        pendingDeletionIds.insert(bookmark.id)
        totalBookmarkCount = max(0, totalBookmarkCount - 1)
        
        guard let idx = bookmarks.firstIndex(where: { $0.id == bookmark.id }) else {
            return (removed: [], deleteIds: [bookmark.id])
        }
        bookmarks.remove(at: idx)
        selectedIds.remove(bookmark.id)
        if selectedBookmark?.id == bookmark.id { selectedBookmark = nil }
        return (removed: [(bookmark: bookmark, index: idx)], deleteIds: [bookmark.id])
    }

    func deleteSelected() -> (removed: [(bookmark: Bookmark, index: Int)], deleteIds: Set<String>) {
        let ids = selectedIds
        pendingDeletionIds.formUnion(ids)
        totalBookmarkCount = max(0, totalBookmarkCount - ids.count)
        
        var removed: [(bookmark: Bookmark, index: Int)] = []
        for (idx, bm) in bookmarks.enumerated() where ids.contains(bm.id) {
            removed.append((bookmark: bm, index: idx))
        }
        bookmarks.removeAll { ids.contains($0.id) }
        if let sel = selectedBookmark, ids.contains(sel.id) { selectedBookmark = nil }
        selectedIds.removeAll()
        return (removed: removed, deleteIds: ids)
    }

    /// Replace local copies of the given bookmarks (e.g. after a tag change),
    /// so the list and preview reflect the change immediately without a reload.
    func applyUpdated(_ updated: [Bookmark]) {
        for bm in updated {
            if let idx = bookmarks.firstIndex(where: { $0.id == bm.id }) { bookmarks[idx] = bm }
            if selectedBookmark?.id == bm.id { selectedBookmark = bm }
        }
    }

    func updateDesignSnapshotStatus(bookmarkId: String, complete: Bool) {
        if let idx = bookmarks.firstIndex(where: { $0.id == bookmarkId }) {
            bookmarks[idx].designSnapshotCapturedAt = Date()
            bookmarks[idx].designSnapshotComplete = complete
        }
        if selectedBookmark?.id == bookmarkId {
            selectedBookmark?.designSnapshotCapturedAt = Date()
            selectedBookmark?.designSnapshotComplete = complete
        }
    }

    /// Remove a deleted tag from every local bookmark so its chip disappears
    /// immediately, without waiting for a reload.
    func removeTagLocally(_ tagId: String) {
        for i in bookmarks.indices {
            bookmarks[i].tags.removeAll { $0.id == tagId }
        }
        selectedBookmark?.tags.removeAll { $0.id == tagId }
    }

    /// Reflect a renamed/recolored tag across every local bookmark immediately.
    func updateTagLocally(_ tag: Tag) {
        for i in bookmarks.indices {
            for j in bookmarks[i].tags.indices where bookmarks[i].tags[j].id == tag.id {
                bookmarks[i].tags[j] = tag
            }
        }
        if var sel = selectedBookmark {
            for j in sel.tags.indices where sel.tags[j].id == tag.id { sel.tags[j] = tag }
            selectedBookmark = sel
        }
    }

    func updateBookmark(_ bookmark: Bookmark, update: BookmarkUpdate) async throws {
        let updated = try await api.updateBookmark(id: bookmark.id, body: update)
        if let idx = bookmarks.firstIndex(where: { $0.id == bookmark.id }) { bookmarks[idx] = updated }
        if selectedBookmark?.id == bookmark.id { selectedBookmark = updated }
    }

    func updateNotes(_ bookmark: Bookmark, notes: String) async throws {
        var update = BookmarkUpdate()
        update.notes = notes
        try await updateBookmark(bookmark, update: update)
    }

    func addNote(to bookmark: Bookmark, content: String, source: String = "user") async throws {
        let note = try await api.addNote(bookmarkId: bookmark.id, content: content, source: source)
        if let idx = bookmarks.firstIndex(where: { $0.id == bookmark.id }) {
            bookmarks[idx].bookmarkNotes.insert(note, at: 0)
        }
        if selectedBookmark?.id == bookmark.id {
            selectedBookmark?.bookmarkNotes.insert(note, at: 0)
        }
    }

    func deleteNote(_ noteId: String, from bookmark: Bookmark) async throws {
        try await api.deleteNote(bookmarkId: bookmark.id, noteId: noteId)
        if let idx = bookmarks.firstIndex(where: { $0.id == bookmark.id }) {
            bookmarks[idx].bookmarkNotes.removeAll { $0.id == noteId }
        }
        if selectedBookmark?.id == bookmark.id {
            selectedBookmark?.bookmarkNotes.removeAll { $0.id == noteId }
        }
    }

    func moveToCollection(ids: Set<String>, collectionId: String?) async throws {
        for id in ids {
            var update = BookmarkUpdate()
            update.collectionId = collectionId
            _ = try await api.updateBookmark(id: id, body: update)
        }
        // Notify that folder counts need refresh
        NotificationCenter.default.post(name: .bookmarksMoved, object: nil)
    }

    func addBookmarkFromURL(_ urlString: String, collectionId: String? = nil) async throws -> Bookmark {
        let bm = try await api.createBookmark(.init(
            title: "", url: urlString, description: nil, notes: nil,
            collectionId: collectionId, tagIds: [], source: "manual"
        ))
        bookmarks.insert(bm, at: 0)
        selectedBookmark = bm
        selectedIds = [bm.id]
        totalBookmarkCount += 1
        return bm
    }

    // MARK: - Metadata

    func fetchMeta(_ bookmark: Bookmark) async throws {
        if let status = bookmark.analysis?.metadata,
           status == "pending" || status == "running" { return }
        let needsMeta = bookmark.ogImageUrl == nil && bookmark.description == nil
        let needsOgCache = bookmark.ogImageUrl != nil && bookmark.ogImagePath == nil
        let needsFavicon = bookmark.faviconPath == nil
        guard needsMeta || needsOgCache || needsFavicon else { return }
        guard !metaAttempted.contains(bookmark.id) else { return }
        metaAttempted.insert(bookmark.id)
        let updated = try await api.fetchMeta(id: bookmark.id)
        if let idx = bookmarks.firstIndex(where: { $0.id == bookmark.id }) { bookmarks[idx] = updated }
        if selectedBookmark?.id == bookmark.id { selectedBookmark = updated }
    }

    func retryAnalysis(ids: Set<String>) async throws {
        for id in ids {
            let updated = try await api.retryBookmarkAnalysis(id: id)
            if let index = bookmarks.firstIndex(where: { $0.id == id }) {
                bookmarks[index] = updated
            }
            if selectedBookmark?.id == id { selectedBookmark = updated }
        }
    }

    // MARK: - Search

    func scheduleSearch(_ query: String, onSearch: (() async -> Void)? = nil) {
        searchTask?.cancel()
        searchQuery = query
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            if let onSearch = onSearch {
                await onSearch()
            } else {
                try? await loadBookmarks(query: query)
            }
        }
    }

    func setSort(by field: String, order: String) async throws {
        sortBy = field
        sortOrder = order
        try await loadBookmarks(query: searchQuery)
    }

    // MARK: - Browser

    func openInBrowser(ids: Set<String>) {
        bookmarks.filter { ids.contains($0.id) }.forEach { safeBrowserOpen($0.url) }
    }

    func safeBrowserOpen(_ urlString: String) {
        guard let url = URL(string: urlString),
              url.scheme == "https" || url.scheme == "http" else { return }
        NSWorkspace.shared.open(url)
    }

}
