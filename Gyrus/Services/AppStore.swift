import Foundation
import Combine
import AppKit

@MainActor
@Observable
final class AppStore {
    static let shared = AppStore()

    let bookmarksStore = BookmarkStore()
    let collectionsStore = CollectionStore()
    let tagsStore = TagStore()
    let uiStateStore = UIStateStore()

    let api = APIClient.shared  // internal: AppStore+Tags.swift uses it
    private var pendingDeleteTask: Task<Void, Never>?
    private var autoRefreshTask: Task<Void, Never>?
    private let linkCheckPoller = JobPoller<LinkCheckStatus>()
    private let metadataPoller = JobPoller<MetadataRefreshStatus>()
    private let batchTagPoller = JobPoller<BatchAutoTagStatus>()
    static let undoWindow: TimeInterval = 5

    func loadAll() async {
        uiStateStore.isLoading = true
        defer { uiStateStore.isLoading = false }
        
        // Refresh counts when bookmarks are moved
        NotificationCenter.default.removeObserver(self, name: .bookmarksMoved, object: nil)
        NotificationCenter.default.addObserver(
            forName: .bookmarksMoved,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { try? await self?.collectionsStore.fetchCollections() }
        }

        async let bmsResult: Void? = try? await bookmarksStore.loadBookmarks(
            collectionId: collectionsStore.selectedCollectionId,
            tagName: tagsStore.selectedTagName,
            showDeadOnly: collectionsStore.showDeadOnly,
            unreadOnly: collectionsStore.showUnreadOnly,
            showTrash: collectionsStore.showTrash,
            query: bookmarksStore.searchQuery
        )
        async let colsResult: Void? = try? await collectionsStore.fetchCollections()
        async let tagsResult: Void? = try? await tagsStore.fetchTags()
        async let totalResult: Int? = try? await api.bookmarkCount()
        async let deadResult: Int? = try? await api.deadBookmarkCount()
        async let unreadResult: Int? = try? await api.unreadBookmarkCount()
        async let trashResult: Int? = try? await api.trashCount()

        let _ = await (bmsResult, colsResult, tagsResult, totalResult, deadResult, unreadResult, trashResult)

        if let n = await totalResult { bookmarksStore.totalBookmarkCount = n }
        if let d = await deadResult { bookmarksStore.deadBookmarkCount = d }
        if let u = await unreadResult { bookmarksStore.unreadBookmarkCount = u }
        if let tr = await trashResult { bookmarksStore.trashCount = tr }

        startAutoRefreshPolling()

        // Check semantic search availability (non-blocking).
        Task {
            if let status = try? await api.semanticSearchStatus() {
                bookmarksStore.semanticSearchAvailable = status.available
            }
        }
    }

    func stopAutoRefreshPolling() {
        autoRefreshTask?.cancel()
        autoRefreshTask = nil
    }

    private func startAutoRefreshPolling() {
        guard autoRefreshTask == nil else { return }
        autoRefreshTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000) // poll every 5 seconds
                guard !Task.isCancelled else { return }

                // Skip while we're actively loading, recovering the backend
                // (wake-from-sleep), or running a link check — otherwise the
                // poll can race the reconnect and surface a transient 404.
                guard !uiStateStore.isLoading,
                      !isRecovering,
                      uiStateStore.linkCheckStatus?.running != true else { continue }
                
                do {
                    let serverCount = try await api.bookmarkCount()
                    let localTotal = bookmarksStore.totalBookmarkCount + bookmarksStore.pendingDeletionIds.count

                    if serverCount != localTotal {
                        await loadAll()
                    }
                } catch {
                    // Ignore background-polling errors.
                }

                // Re-check semantic availability if Ollama wasn't ready at startup.
                if !bookmarksStore.semanticSearchAvailable {
                    if let status = try? await api.semanticSearchStatus() {
                        bookmarksStore.semanticSearchAvailable = status.available
                    }
                }
            }
        }
    }

    func importHTML(data: Data, filename: String, rootFolderName: String? = nil) async throws -> ImportResult {
        let result = try await api.importHTML(data: data, filename: filename, rootFolderName: rootFolderName)
        await loadAll()
        return result
    }

    // MARK: - Search

    /// Route an error from a user-triggered action to the error toast, with the
    /// same noise filtering as handleUIError. Internal (not private) so view
    /// callbacks (e.g. sidebar context-menu actions) can surface failures
    /// instead of swallowing them with `try?`.
    func surfaceError(_ error: Error) {
        handleUIError(error)
    }

    private func handleUIError(_ error: Error) {
        // Debounced search cancels in-flight tasks — never show that to the user.
        if error is CancellationError { return }
        // Suppress connection errors while the app is returning from background/sleep,
        // and cancelled URLSessions (debounce / task cancellation).
        if case APIError.networkError(let inner) = error,
           let urlError = inner as? URLError,
           urlError.code == .cannotConnectToHost ||
           urlError.code == .notConnectedToInternet ||
           urlError.code == .networkConnectionLost ||
           urlError.code == .cancelled {
            return
        }
        // A background list/count/search refresh that hits a transient
        // infrastructure error (the backend briefly restarting after the Mac
        // wakes — 404 on a normally-valid route, 501, or any 5xx) is
        // self-healing: the poll and recoverConnection() refetch moments later.
        // These are never actionable, so never toast them. (A genuine backend
        // outage surfaces via the StartupView / retry path instead.) This is
        // unconditional on purpose — the old isRecovering/grace check raced with
        // errors that land at the exact focus moment.
        if case APIError.serverError(let code) = error,
           code == 404 || code == 501 || code >= 500 {
            return
        }
        uiStateStore.showError(error.localizedDescription)
    }

    func scheduleSearch(_ query: String) {
        bookmarksStore.scheduleSearch(query) { [weak self] in
            await self?.loadBookmarks()
        }
    }

    func loadBookmarks() async {
        do {
            try await bookmarksStore.loadBookmarks(
                collectionId: collectionsStore.selectedCollectionId,
                tagName: tagsStore.selectedTagName,
                showDeadOnly: collectionsStore.showDeadOnly,
                unreadOnly: collectionsStore.showUnreadOnly,
                showTrash: collectionsStore.showTrash,
                query: bookmarksStore.searchQuery
            )
        } catch {
            handleUIError(error)
        }
    }

    /// Change the sort and reload **within the current view** (folder/tag/search).
    /// Going through here keeps the active filter — sorting via the store directly
    /// would reload all bookmarks and ignore the open folder.
    func setSort(by field: String, order: String) async {
        bookmarksStore.sortBy = field
        bookmarksStore.sortOrder = order
        await loadBookmarks()
    }

    /// Move bookmarks to another folder, then reload the current view so the
    /// moved bookmarks immediately leave the folder you're looking at (instead
    /// of lingering until the next click).
    func moveBookmarks(ids: Set<String>, to collectionId: String?) async {
        do {
            try await bookmarksStore.moveToCollection(ids: ids, collectionId: collectionId)
            bookmarksStore.selectedIds.subtract(ids)
            if let sel = bookmarksStore.selectedBookmark, ids.contains(sel.id) {
                bookmarksStore.selectedBookmark = nil
            }
            // If we're viewing a specific folder and the bookmarks moved OUT of
            // it, drop them from the list right away — in place, so the scroll
            // position is kept (a full reload would jump back to the top, and on
            // a long paginated list the removal wouldn't even be visible).
            let inSpecificFolder = collectionsStore.selectedCollectionId != nil
                && tagsStore.selectedTagName == nil
                && bookmarksStore.searchQuery.isEmpty
            if inSpecificFolder && collectionId != collectionsStore.selectedCollectionId {
                bookmarksStore.bookmarks.removeAll { ids.contains($0.id) }
                bookmarksStore.totalBookmarkCount = max(0, bookmarksStore.totalBookmarkCount - ids.count)
            }
        } catch {
            handleUIError(error)
        }
    }

    /// Ask the backend to stop the metadata refresh. Already-fetched data is kept.
    func cancelMetadataRefresh() async {
        do {
            uiStateStore.metadataRefreshStatus = try await api.cancelMetadataRefresh()
        } catch {
            handleUIError(error)
        }
    }

    // MARK: - Connection Recovery

    private var isRecovering = false

    /// Called when the app returns to the foreground or the Mac wakes from
    /// sleep. The backend (a child process) can become unreachable across sleep,
    /// which also makes favicons fall back to the globe. Re-check the backend,
    /// restart it if needed, and refresh the UI so icons come back.
    func recoverConnection() async {
        guard !isRecovering else { return }
        isRecovering = true
        defer { isRecovering = false }

        // Mute transient error toasts for the whole recovery, not just the
        // brief grace set on wake — an actual restart can take a few seconds.
        uiStateStore.beginResumeGrace(8)

        // Right after wake-from-sleep the backend can be momentarily slow to
        // answer (its process was suspended). Retry the lightweight health
        // check a few times before concluding it must be restarted — otherwise
        // we needlessly kill a perfectly alive backend, and that restart window
        // is exactly what produced the transient "Server error 404".
        var healthy = false
        for attempt in 0..<4 {
            if (try? await api.health()) == true { healthy = true; break }
            if attempt < 3 { try? await Task.sleep(nanoseconds: 500_000_000) }
        }

        if !healthy {
            await BackendLauncher.shared.start()
            guard BackendLauncher.shared.isRunning else { return }
            try? await api.updateAIBrainConfig(AppSettings.shared.aiBrainConfig)
            await loadAll()
            // A real restart briefly failed in-flight requests; keep them muted
            // a moment longer now that the backend is back up.
            uiStateStore.beginResumeGrace(3)
        }
        FaviconCache.shared.refresh()
    }

    // MARK: - Link Check

    func startLinkCheck() async {
        do {
            let status = try await api.startLinkCheck()
            uiStateStore.linkCheckStatus = status
            linkCheckPoller.start(
                interval: 1.5,
                fetch: { [api] in try await api.linkCheckStatus() },
                onTick: { [weak self] status in
                    self?.uiStateStore.linkCheckStatus = status
                },
                onFinished: { [weak self] _ in
                    guard let self else { return }
                    if let d = try? await self.api.deadBookmarkCount() {
                        self.bookmarksStore.deadBookmarkCount = d
                    }
                    await self.loadBookmarks()
                }
            )
        } catch {
            handleUIError(error)
        }
    }

    // MARK: - Metadata Refresh

    /// Force a re-fetch of favicons, descriptions and preview images for every
    /// bookmark (heals broken/stale metadata). Runs in the background and polls
    /// for progress, then reloads the list so the new favicons appear.
    func startMetadataRefresh() async {
        guard uiStateStore.metadataRefreshStatus?.running != true else { return }
        do {
            uiStateStore.metadataRefreshStatus = try await api.startMetadataRefresh()
            metadataPoller.start(
                interval: 1.0,
                fetch: { [api] in try await api.metadataRefreshStatus() },
                onTick: { [weak self] status in
                    self?.uiStateStore.metadataRefreshStatus = status
                },
                onFinished: { [weak self] status in
                    guard let self else { return }
                    // Bust cached favicon images (same filename → same URL)
                    // so the freshly fetched icons actually show, then reload.
                    URLCache.shared.removeAllCachedResponses()
                    FaviconCache.shared.clear()
                    await self.loadBookmarks()
                    if status.updated > 0 {
                        self.uiStateStore.showInfo(AppSettings.shared.localized("Updated \(status.updated) bookmarks."))
                    }
                }
            )
        } catch {
            handleUIError(error)
        }
    }

    /// A taxonomy needs shared categories (each backed by ≥2 bookmarks);
    /// below this the run is guaranteed to fail. Mirrors the backend's
    /// MIN_TAXONOMY_BOOKMARKS in auto_tag_batch_service.py.
    static let minTaxonomyBookmarks = 10

    /// Build one shared, reviewable tag system for a selection. This is the
    /// slower AI path and never writes tags until the user approves the draft.
    func startTaxonomyReview(ids: [String]) async {
        guard uiStateStore.batchAutoTagStatus?.running != true else { return }
        guard ids.count >= Self.minTaxonomyBookmarks else {
            uiStateStore.showError(AppSettings.shared.localized(
                "Select at least \(Self.minTaxonomyBookmarks) bookmarks to build a tag system."
            ))
            return
        }
        let config = AppSettings.shared.aiBrainConfig
        guard config.aiEnabled else {
            uiStateStore.showError(AppSettings.shared.localized("Enable AI to review a tag system."))
            return
        }
        do {
            uiStateStore.batchTagFailure = nil
            uiStateStore.batchAutoTagStatus = try await api.startBatchAutoTag(ids: ids, config: config)
            uiStateStore.showInfo(AppSettings.shared.localized("Analyzing \(ids.count) bookmarks…"))
            batchTagPoller.start(
                interval: 1.5,
                fetch: { [api] in try await api.batchAutoTagStatus() },
                onTick: { [weak self] status in
                    self?.uiStateStore.batchAutoTagStatus = status
                },
                onFinished: { [weak self] status in
                    guard let self else { return }
                    self.uiStateStore.batchAutoTagStatus = nil
                    if let draft = status.draft {
                        self.uiStateStore.batchTagReview = TagReviewPayload(draft: draft)
                    } else if let error = status.error?.trimmingCharacters(in: .whitespacesAndNewlines),
                              !error.isEmpty {
                        self.uiStateStore.batchTagFailure = error
                    } else if status.phase != "cancelled" {
                        self.uiStateStore.batchTagFailure = AppSettings.shared.localized(
                            "No tag system could be created."
                        )
                    }
                }
            )
        } catch {
            uiStateStore.batchAutoTagStatus = nil
            handleUIError(error)
        }
    }

    func cancelBatchAutoTag() async {
        batchTagPoller.stop()
        _ = try? await api.cancelBatchAutoTag()
        uiStateStore.batchAutoTagStatus = nil
        uiStateStore.showInfo(AppSettings.shared.localized("Analysis stopped. No tags were changed."))
    }




    // MARK: - Batch Actions & Undo

    private let batchThreshold = 10

    func requestDeleteSelected() {
        let ids = bookmarksStore.selectedIds
        let confirmEnabled = AppSettings.shared.confirmDelete
        if confirmEnabled && ids.count > batchThreshold {
            uiStateStore.pendingBatchDelete = ids
        } else {
            Task { await deleteSelected() }
        }
    }

    func confirmPendingDelete() {
        guard let ids = uiStateStore.pendingBatchDelete else { return }
        uiStateStore.pendingBatchDelete = nil
        bookmarksStore.selectedIds = ids
        Task { await deleteSelected() }
    }

    func cancelPendingDelete() {
        uiStateStore.pendingBatchDelete = nil
    }

    func deleteSelected() async {
        let result = bookmarksStore.deleteSelected()
        scheduleUndoDelete(removed: result.removed, deleteIds: result.deleteIds)
    }

    func deleteBookmark(_ bookmark: Bookmark) async {
        let result = bookmarksStore.deleteBookmark(bookmark)
        scheduleUndoDelete(removed: result.removed, deleteIds: result.deleteIds)
    }


    func requestOpenInBrowser(ids: Set<String>) {
        if ids.count > batchThreshold {
            uiStateStore.pendingBatchOpen = ids
        } else {
            bookmarksStore.openInBrowser(ids: ids)
        }
    }

    func confirmPendingOpen() {
        guard let ids = uiStateStore.pendingBatchOpen else { return }
        uiStateStore.pendingBatchOpen = nil
        bookmarksStore.openInBrowser(ids: ids)
    }

    func cancelPendingOpen() {
        uiStateStore.pendingBatchOpen = nil
    }

    func selectAllInCurrentView() async {
        do {
            try await bookmarksStore.selectAllInCurrentView(
                collectionId: collectionsStore.selectedCollectionId,
                tagName: tagsStore.selectedTagName,
                showDeadOnly: collectionsStore.showDeadOnly,
                unreadOnly: collectionsStore.showUnreadOnly,
                showTrash: collectionsStore.showTrash,
                query: bookmarksStore.searchQuery
            )
        } catch {
            handleUIError(error)
        }
    }

    func selectNavigation(id: String?) async {
        // Reset filters
        collectionsStore.selectedCollectionId = nil
        collectionsStore.showDeadOnly = false
        collectionsStore.showUnreadOnly = false
        collectionsStore.showTrash = false
        tagsStore.selectedTagName = nil

        if let id = id {
            if id == "__dead__" {
                collectionsStore.showDeadOnly = true
            } else if id == "__unread__" {
                collectionsStore.showUnreadOnly = true
            } else if id == "__trash__" {
                collectionsStore.showTrash = true
            } else if id.hasPrefix("tag:") {
                tagsStore.selectedTagName = String(id.dropFirst(4))
            } else {
                collectionsStore.selectedCollectionId = id
            }
        }

        await loadBookmarks()
    }

    // MARK: - Read / Unread & Trash actions

    func setRead(ids: Set<String>, isRead: Bool) async {
        do {
            try await bookmarksStore.setRead(ids: ids, isRead: isRead)
            if let n = try? await api.unreadBookmarkCount() { bookmarksStore.unreadBookmarkCount = n }
        } catch { handleUIError(error) }
    }

    func toggleRead(_ bookmark: Bookmark) async {
        do {
            try await bookmarksStore.setRead(bookmark, isRead: !bookmark.isRead)
            if let n = try? await api.unreadBookmarkCount() { bookmarksStore.unreadBookmarkCount = n }
        } catch { handleUIError(error) }
    }

    /// Move bookmarks to the Trash directly (used by drag-to-trash in the
    /// sidebar). Removes them from the current view and refreshes counts.
    func trashBookmarks(ids: Set<String>) async {
        guard !ids.isEmpty else { return }
        do {
            try await api.deleteBookmarks(ids: ids)
            bookmarksStore.bookmarks.removeAll { ids.contains($0.id) }
            bookmarksStore.selectedIds.subtract(ids)
            if let sel = bookmarksStore.selectedBookmark, ids.contains(sel.id) {
                bookmarksStore.selectedBookmark = nil
            }
            await refreshCounts()
        } catch { handleUIError(error) }
    }

    func restoreFromTrash(ids: Set<String>) async {
        do {
            try await bookmarksStore.restoreFromTrash(ids: ids)
            await refreshCounts()
        } catch { handleUIError(error) }
    }

    func emptyTrash() async {
        do {
            try await bookmarksStore.purgeTrash(ids: nil)
        } catch { handleUIError(error) }
    }

    func purgeFromTrash(ids: Set<String>) async {
        do {
            try await bookmarksStore.purgeTrash(ids: ids)
        } catch { handleUIError(error) }
    }

    private func refreshCounts() async {
        if let t = try? await api.bookmarkCount() { bookmarksStore.totalBookmarkCount = t }
        if let d = try? await api.deadBookmarkCount() { bookmarksStore.deadBookmarkCount = d }
        if let u = try? await api.unreadBookmarkCount() { bookmarksStore.unreadBookmarkCount = u }
        if let tr = try? await api.trashCount() { bookmarksStore.trashCount = tr }
    }

    func requestDeleteAll(deadOnly: Bool) async {
        do {
            let ids = try await api.bookmarkIds(deadOnly: deadOnly)
            guard !ids.isEmpty else { return }
            bookmarksStore.selectedIds = Set(ids)
            requestDeleteSelected()
        } catch {
            handleUIError(error)
        }
    }

    // MARK: - Data Management

    enum ResetType: String {
        case cache, brain, bookmarks, factory
    }

    func handleReset(type: ResetType) async throws {
        switch type {
        case .cache:
            try await api.clearCache()
        case .brain:
            try await api.clearBrain()
        case .bookmarks:
            try await api.clearBookmarks()
            bookmarksStore.bookmarks = []
            bookmarksStore.selectedBookmark = nil
            bookmarksStore.selectedIds = []
            bookmarksStore.totalBookmarkCount = 0
            bookmarksStore.deadBookmarkCount = 0
            collectionsStore.collections = []
            collectionsStore.selectedCollectionId = nil
            tagsStore.tags = []
            tagsStore.selectedTagName = nil
        case .factory:
            try await api.factoryReset()
            bookmarksStore.bookmarks = []
            bookmarksStore.selectedBookmark = nil
            bookmarksStore.selectedIds = []
            bookmarksStore.totalBookmarkCount = 0
            bookmarksStore.deadBookmarkCount = 0
            collectionsStore.collections = []
            collectionsStore.selectedCollectionId = nil
            tagsStore.tags = []
            tagsStore.selectedTagName = nil
            if let bundleID = Bundle.main.bundleIdentifier {
                UserDefaults.standard.removePersistentDomain(forName: bundleID)
            }
        }
        await loadAll()
    }

    private func scheduleUndoDelete(removed: [(bookmark: Bookmark, index: Int)],
                                    deleteIds: Set<String>) {
        uiStateStore.cancelUndoTimer()
        uiStateStore.undoGeneration += 1

        let count = deleteIds.count
        
        // Only show Undo and require confirmation for more than 10 bookmarks.
        // For small deletions, we delete immediately on the server.
        if count <= 10 {
            uiStateStore.undoMessage = nil
            uiStateStore.undoAction = nil
            
            pendingDeleteTask = Task { [weak self] in
                guard let self else { return }
                do {
                    try await self.api.deleteBookmarks(ids: deleteIds)
                } catch {
                    await MainActor.run { self.uiStateStore.showError(String(localized: "Delete failed: \(error.localizedDescription)")) }
                }
                await MainActor.run {
                    self.bookmarksStore.pendingDeletionIds.subtract(deleteIds)
                }
                await self.loadAll()
            }
            return
        }

        uiStateStore.undoMessage = AppSettings.shared.localized("Deleted \(count) bookmarks")

        uiStateStore.undoAction = { [weak self] in
            guard let self else { return }
            self.pendingDeleteTask?.cancel()
            self.uiStateStore.cancelUndoTimer()
            
            // Clear pending IDs immediately on undo
            self.bookmarksStore.pendingDeletionIds.subtract(deleteIds)
            
            let sorted = removed.sorted { $0.index < $1.index }
            for item in sorted {
                let insertAt = min(item.index, self.bookmarksStore.bookmarks.count)
                self.bookmarksStore.bookmarks.insert(item.bookmark, at: insertAt)
            }
            if let first = sorted.first {
                self.bookmarksStore.selectedBookmark = first.bookmark
                self.bookmarksStore.selectedIds = Set(sorted.map { $0.bookmark.id })
            }
            self.uiStateStore.undoMessage = nil
            self.uiStateStore.undoAction = nil
            Task { await self.loadBookmarks() }
        }

        uiStateStore.startUndoTimer(window: Self.undoWindow)

        pendingDeleteTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: UInt64(Self.undoWindow * 1_000_000_000))
            guard !Task.isCancelled else { return }
            
            // Delete in chunks of 500 to keep request size and DB variables safe.
            let chunkSize = 500
            let allIds = Array(deleteIds)
            for i in stride(from: 0, to: allIds.count, by: chunkSize) {
                let chunk = Set(allIds[i..<min(i + chunkSize, allIds.count)])
                do {
                    try await self.api.deleteBookmarks(ids: chunk)
                } catch {
                    await MainActor.run { self.uiStateStore.showError(String(localized: "Delete failed: \(error.localizedDescription)")) }
                }
            }
            
            // Cleanup pending list after actual server delete
            await MainActor.run {
                self.bookmarksStore.pendingDeletionIds.subtract(deleteIds)
            }
            
            await self.loadAll() // Full refresh to sync counts and lists
        }
    }
}
