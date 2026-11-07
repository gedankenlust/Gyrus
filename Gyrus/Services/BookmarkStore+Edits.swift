import Foundation
import AppKit

// MARK: - Counts, local edits, CRUD, metadata, browser

extension BookmarkStore {
    /// Server counts still include bookmarks whose delete is waiting out the
    /// undo window. Subtract them here so the sidebar matches the list and the
    /// auto-refresh comparison (server == local + pending) settles.
    func applyCounts(_ counts: BookmarkCounts) {
        totalBookmarkCount = max(0, counts.total - pendingDeletionIds.count)
        deadBookmarkCount = counts.dead
        unreadBookmarkCount = counts.unread
        trashCount = counts.trash
    }

    func refreshSemanticSearchStatus() async {
        if let status = try? await api.semanticSearchStatus() {
            semanticSearchAvailable = status.available
        }
    }

    // MARK: Local edits

    /// Drop rows that left the current view, and any selection of them.
    func removeRows(_ ids: Set<String>) {
        bookmarks.removeAll { ids.contains($0.id) }
        selectedIds.subtract(ids)
        if let selected = selectedBookmark, ids.contains(selected.id) { selectedBookmark = nil }
    }

    /// Replace local copies of the given bookmarks (e.g. after a tag change),
    /// so the list and preview reflect the change immediately without a reload.
    func applyUpdated(_ updated: [Bookmark]) {
        let replacements = Dictionary(uniqueKeysWithValues: updated.map { ($0.id, $0) })
        bookmarks = bookmarks.map { replacements[$0.id] ?? $0 }
        if let selected = selectedBookmark,
           let replacement = replacements[selected.id] {
            selectedBookmark = replacement
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
        var changed = bookmarks
        for index in changed.indices {
            changed[index].tags.removeAll { $0.id == tagId }
        }
        bookmarks = changed
        selectedBookmark?.tags.removeAll { $0.id == tagId }
    }

    /// Reflect a renamed/recolored tag across every local bookmark immediately.
    func updateTagLocally(_ tag: Tag) {
        var changed = bookmarks
        for bookmarkIndex in changed.indices {
            for tagIndex in changed[bookmarkIndex].tags.indices
            where changed[bookmarkIndex].tags[tagIndex].id == tag.id {
                changed[bookmarkIndex].tags[tagIndex] = tag
            }
        }
        bookmarks = changed
        if var sel = selectedBookmark {
            for j in sel.tags.indices where sel.tags[j].id == tag.id { sel.tags[j] = tag }
            selectedBookmark = sel
        }
    }

    // MARK: Read / Unread

    /// Toggle (or set) the read state and update local copies immediately.
    func setRead(_ bookmark: Bookmark, isRead: Bool) async throws {
        var update = BookmarkUpdate()
        update.isRead = isRead
        try await updateBookmark(bookmark, update: update)
    }

    func setRead(ids: Set<String>, isRead: Bool) async throws {
        _ = try await api.setBookmarksRead(ids: ids, isRead: isRead)
        for index in bookmarks.indices where ids.contains(bookmarks[index].id) {
            bookmarks[index].isRead = isRead
        }
        if let selected = selectedBookmark, ids.contains(selected.id) {
            selectedBookmark?.isRead = isRead
        }
    }

    // MARK: CRUD

    func updateBookmark(_ bookmark: Bookmark, update: BookmarkUpdate) async throws {
        let updated = try await api.updateBookmark(id: bookmark.id, body: update)
        if let idx = bookmarks.firstIndex(where: { $0.id == bookmark.id }) { bookmarks[idx] = updated }
        if selectedBookmark?.id == bookmark.id { selectedBookmark = updated }
    }

    func moveToCollection(ids: Set<String>, collectionId: String?) async throws {
        _ = try await api.moveBookmarks(ids: ids, collectionId: collectionId)
        for index in bookmarks.indices where ids.contains(bookmarks[index].id) {
            bookmarks[index].collectionId = collectionId
        }
        if let selected = selectedBookmark, ids.contains(selected.id) {
            selectedBookmark?.collectionId = collectionId
        }
        // Notify that folder counts need refresh
        NotificationCenter.default.post(name: .bookmarksMoved, object: nil)
    }

    func addBookmarkFromURL(_ urlString: String, collectionId: String? = nil) async throws -> Bookmark {
        let bm = try await api.createBookmark(.init(
            title: URL(string: urlString)?.host ?? urlString, url: urlString, description: nil, notes: nil,
            collectionId: collectionId, tagIds: [], source: "manual"
        ))
        bookmarks.insert(bm, at: 0)
        selectedBookmark = bm
        selectedIds = [bm.id]
        totalBookmarkCount += 1
        return bm
    }

    // MARK: Details & Metadata

    func loadDetails(id: String) async throws {
        let trashed = loadContext.showTrash
        let generation = libraryGeneration
        let details = try await api.bookmark(id: id, trashed: trashed)
        guard generation == libraryGeneration, selectedBookmark?.id == id else { return }
        applyUpdated([details])
    }

    func fetchMeta(_ bookmark: Bookmark) async throws {
        if let status = bookmark.analysis?.metadata,
           status == "pending" || status == "running" { return }
        let needsMeta = bookmark.ogImageUrl == nil && bookmark.description == nil
        let needsOgCache = bookmark.ogImageUrl != nil && bookmark.ogImagePath == nil
        let needsFavicon = bookmark.faviconPath == nil
        guard needsMeta || needsOgCache || needsFavicon else { return }
        guard !metaAttempted.contains(bookmark.id) else { return }
        metaAttempted.insert(bookmark.id)
        let generation = libraryGeneration
        let updated: Bookmark
        do { updated = try await api.fetchMeta(id: bookmark.id) }
        catch {
            if error is CancellationError && generation == libraryGeneration {
                metaAttempted.remove(bookmark.id)
            }
            throw error
        }
        guard generation == libraryGeneration, !Task.isCancelled else { return }
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

    // MARK: Browser

    func openInBrowser(ids: Set<String>) {
        var targets = bookmarks.filter { ids.contains($0.id) }
        // A Quick Search result can be selected while it is outside the loaded
        // rows; it is still the previewed bookmark, so ⌘O must open it.
        if let selected = selectedBookmark, ids.contains(selected.id),
           !targets.contains(where: { $0.id == selected.id }) {
            targets.append(selected)
        }
        targets.forEach { safeBrowserOpen($0.url) }
    }

    func safeBrowserOpen(_ urlString: String) {
        guard let url = URL(string: urlString),
              url.scheme == "https" || url.scheme == "http" else { return }
        NSWorkspace.shared.open(url)
    }
}
