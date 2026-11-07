import Foundation
import Combine

/// Composes the library's state and the controllers that act on it, and
/// owns what spans them: loading the current view, navigation, search, sort
/// and move.
///
///   jobs        BackgroundJobs       link check, metadata refresh, folder sort, taxonomy review
///   trash       TrashController      delete with undo, trash, purge, their confirmations
///   connection  ConnectionMonitor    auto-refresh poll, recovery after sleep
/// Resets are in AppStore+Library.swift, tag operations in AppStore+Tags.swift.
@MainActor
@Observable
final class AppStore: LibraryReloading {
    static let shared = AppStore()

    let bookmarksStore: BookmarkStore
    let collectionsStore: CollectionStore
    let tagsStore: TagStore
    let uiStateStore: UIStateStore
    let jobs: BackgroundJobs
    let trash: TrashController
    let connection: ConnectionMonitor

    let api: APIClient  // internal: the AppStore+*.swift extensions use it
    /// Set while a restore or reset swaps the library underneath the window.
    private(set) var isReplacingLibrary = false
    /// Bumped by a library replacement so a load of the old library is dropped.
    private var libraryGeneration = 0
    var loadError: String?
    @ObservationIgnored private var bookmarksMovedObserver: AnyCancellable?

    /// Opening more than this many tabs at once asks first.
    private let batchThreshold = 10

    init(api: APIClient = .shared, draftStorage: NoteDraftStorage? = .applicationStorage) {
        let bookmarks = BookmarkStore(api: api, draftStorage: draftStorage)
        let collections = CollectionStore(api: api)
        let ui = UIStateStore()
        let jobs = BackgroundJobs(api: api, ui: ui, bookmarks: bookmarks)
        self.api = api
        self.bookmarksStore = bookmarks
        self.collectionsStore = collections
        self.tagsStore = TagStore(api: api)
        self.uiStateStore = ui
        self.jobs = jobs
        self.trash = TrashController(api: api, bookmarks: bookmarks, collections: collections, ui: ui)
        self.connection = ConnectionMonitor(api: api, ui: ui, bookmarks: bookmarks, jobs: jobs)
        // The controllers reload through their owner; they can only be handed
        // it once every stored property is set.
        jobs.library = self
        trash.library = self
        connection.library = self
    }

    /// Route an error from a user-triggered action to the error toast.
    /// Kept here because views across the app report through it.
    func surfaceError(_ error: Error) {
        uiStateStore.showError(for: error)
    }

    // MARK: - Loading

    private func installBookmarksMovedObserver() {
        guard bookmarksMovedObserver == nil else { return }
        bookmarksMovedObserver = NotificationCenter.default.publisher(for: .bookmarksMoved)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    try? await self?.collectionsStore.fetchCollections()
                }
            }
    }

    func loadAll() async {
        let generation = libraryGeneration
        uiStateStore.beginLoading()
        defer { uiStateStore.endLoading() }

        // Install the block observer exactly once. AnyCancellable owns its
        // lifetime, unlike NotificationCenter's separate observer token.
        installBookmarksMovedObserver()

        do {
            async let bmsResult: Void = await bookmarksStore.loadBookmarks(
                collectionId: collectionsStore.selectedCollectionId,
                tagName: tagsStore.selectedTagName,
                showDeadOnly: collectionsStore.showDeadOnly,
                unreadOnly: collectionsStore.showUnreadOnly,
                showTrash: collectionsStore.showTrash,
                query: bookmarksStore.searchQuery,
                refreshCount: false
            )
            async let colsResult: Void = await collectionsStore.fetchCollections()
            async let tagsResult: Void = await tagsStore.fetchTags()
            async let countsResult: BookmarkCounts = await api.bookmarkCounts()

            let (_, _, _, counts) = try await (bmsResult, colsResult, tagsResult, countsResult)
            guard generation == libraryGeneration else { return }
            bookmarksStore.applyCounts(counts)
            loadError = nil
        } catch {
            // A superseded or cancelled load (e.g. the startup view swapping to
            // the library) is not a failure the user needs to see.
            guard generation == libraryGeneration, !error.isCancellation else { return }
            loadError = String(localized: "The library could not be fully loaded.") + " " + error.localizedDescription
        }

        startAutoRefreshPolling()

        // Check semantic search availability (non-blocking).
        Task { await bookmarksStore.refreshSemanticSearchStatus() }
    }

    /// No polling while a restore or reset is replacing the library.
    private func startAutoRefreshPolling() {
        guard !isReplacingLibrary else { return }
        connection.startAutoRefreshPolling()
    }

    func importHTML(data: Data, filename: String, rootFolderName: String? = nil) async throws -> ImportResult {
        let result = try await api.importHTML(data: data, filename: filename, rootFolderName: rootFolderName)
        await loadAll()
        return result
    }

    func loadBookmarks(showsLoadingIndicator: Bool = true) async {
        if showsLoadingIndicator {
            uiStateStore.beginBookmarkRefresh()
        }
        defer {
            if showsLoadingIndicator {
                uiStateStore.endBookmarkRefresh()
            }
        }
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
            uiStateStore.showError(for: error, background: !showsLoadingIndicator)
        }
    }

    // MARK: - Search, sort, navigation

    func scheduleSearch(_ query: String) {
        bookmarksStore.scheduleSearch(query) { [weak self] in
            await self?.loadBookmarks()
        }
    }

    /// Change the sort and reload **within the current view** (folder/tag/search).
    /// Going through here keeps the active filter.
    func setSort(by field: String, order: String) async {
        bookmarksStore.sortBy = field
        bookmarksStore.sortOrder = order
        await loadBookmarks()
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
            uiStateStore.showError(for: error)
        }
    }

    // MARK: - Bookmark actions

    func retryAnalysis(ids: Set<String>) async {
        do {
            try await bookmarksStore.retryAnalysis(ids: ids)
        } catch {
            uiStateStore.showError(for: error)
        }
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
            uiStateStore.showError(for: error)
        }
    }

    func setRead(ids: Set<String>, isRead: Bool) async {
        do {
            try await bookmarksStore.setRead(ids: ids, isRead: isRead)
            await refreshUnreadCount()
        } catch { uiStateStore.showError(for: error) }
    }

    func toggleRead(_ bookmark: Bookmark) async {
        do {
            try await bookmarksStore.setRead(bookmark, isRead: !bookmark.isRead)
            await refreshUnreadCount()
        } catch { uiStateStore.showError(for: error) }
    }

    private func refreshUnreadCount() async {
        if let n = try? await api.unreadBookmarkCount() { bookmarksStore.unreadBookmarkCount = n }
    }

    // MARK: - Open in browser

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

    // MARK: - Library replacement

    /// Prevent a deferred delete/undo or a job result from being applied to
    /// the replacement library.
    func prepareForLibraryReplacement() async {
        isReplacingLibrary = true
        libraryGeneration += 1
        connection.stopAutoRefreshPolling()
        await trash.cancelPendingDeletes()
        jobs.stopForLibraryReplacement()
    }

    func finishLibraryReplacement() {
        isReplacingLibrary = false
        startAutoRefreshPolling()
    }
}
