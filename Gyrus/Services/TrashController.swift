import Foundation
import Observation

enum PendingPurge: Equatable {
    case all
    case ids(Set<String>)
}

/// Moving bookmarks to the Trash, restoring and purging them, the
/// confirmations in front of those, and the undo window of a delete.
///
/// A delete is optimistic: the rows leave the list at once and their ids are
/// parked in `BookmarkStore.pendingDeletionIds`, so loads and counts hide them
/// while the undo toast is up. Only when the window passes are they sent to
/// the server, in chunks.
@MainActor
@Observable
final class TrashController {
    /// Bookmarks awaiting the "move to Trash?" confirmation.
    var pendingBatchDelete: Set<String>?
    /// A permanent delete from the Trash awaiting confirmation.
    var pendingPurge: PendingPurge?

    /// Set by the owner once it is fully initialized; weak because the owner
    /// also owns this object.
    @ObservationIgnored weak var library: LibraryReloading?

    /// Keeps each delete-batch request and its SQL variable count bounded.
    static let deleteChunkSize = 500

    @ObservationIgnored private let api: APIClient
    @ObservationIgnored private let bookmarks: BookmarkStore
    @ObservationIgnored private let collections: CollectionStore
    @ObservationIgnored private let ui: UIStateStore
    @ObservationIgnored private let confirmsDelete: @MainActor () -> Bool
    @ObservationIgnored private let undoWindow: TimeInterval
    @ObservationIgnored private var pendingDeleteTasks: [UUID: Task<Void, Never>] = [:]

    init(api: APIClient,
         bookmarks: BookmarkStore,
         collections: CollectionStore,
         ui: UIStateStore,
         confirmsDelete: @escaping @MainActor () -> Bool = { AppSettings.shared.confirmDelete },
         undoWindow: TimeInterval = UIStateStore.undoWindow) {
        self.api = api
        self.bookmarks = bookmarks
        self.collections = collections
        self.ui = ui
        self.confirmsDelete = confirmsDelete
        self.undoWindow = undoWindow
    }

    // MARK: - Move to Trash (with undo)

    func requestDeleteSelected() {
        let ids = bookmarks.selectedIds
        guard !ids.isEmpty else { return }
        // In the Trash a delete is permanent; it always asks first.
        if collections.showTrash {
            requestPurge(ids: ids)
            return
        }
        if confirmsDelete() {
            pendingBatchDelete = ids
        } else {
            Task { await deleteSelected() }
        }
    }

    func confirmPendingDelete() {
        guard let ids = pendingBatchDelete else { return }
        pendingBatchDelete = nil
        bookmarks.selectedIds = ids
        Task { await deleteSelected() }
    }

    func cancelPendingDelete() {
        pendingBatchDelete = nil
    }

    func deleteSelected() async {
        let ids = bookmarks.selectedIds
        var removed: [(bookmark: Bookmark, index: Int)] = []
        for (index, bookmark) in bookmarks.bookmarks.enumerated() where ids.contains(bookmark.id) {
            removed.append((bookmark: bookmark, index: index))
        }
        hideUntilCommitted(ids)
        bookmarks.removeRows(ids)
        scheduleUndoDelete(removed: removed, deleteIds: ids)
    }

    func deleteBookmark(_ bookmark: Bookmark) async {
        hideUntilCommitted([bookmark.id])
        var removed: [(bookmark: Bookmark, index: Int)] = []
        // A previewed bookmark outside the loaded rows (a Quick Search hit)
        // keeps its selection; only a listed row leaves the list.
        if let index = bookmarks.bookmarks.firstIndex(where: { $0.id == bookmark.id }) {
            removed = [(bookmark: bookmark, index: index)]
            bookmarks.removeRows([bookmark.id])
        }
        scheduleUndoDelete(removed: removed, deleteIds: [bookmark.id])
    }

    /// Server counts still include these until the delete is committed;
    /// `BookmarkStore.applyCounts` subtracts them again.
    private func hideUntilCommitted(_ ids: Set<String>) {
        bookmarks.pendingDeletionIds.formUnion(ids)
        bookmarks.totalBookmarkCount = max(0, bookmarks.totalBookmarkCount - ids.count)
    }

    private func scheduleUndoDelete(removed: [(bookmark: Bookmark, index: Int)], deleteIds: Set<String>) {
        let operationID = UUID()
        ui.offerUndo(String(localized: "Deleted \(deleteIds.count) bookmarks"), window: undoWindow) { [weak self] in
            self?.undoDelete(operationID: operationID, removed: removed, deleteIds: deleteIds)
        }
        pendingDeleteTasks[operationID] = Task { [weak self] in
            guard let self else { return }
            defer { self.pendingDeleteTasks[operationID] = nil }
            try? await Task.sleep(nanoseconds: UInt64(self.undoWindow * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self.commitDelete(deleteIds)
        }
    }

    private func undoDelete(operationID: UUID, removed: [(bookmark: Bookmark, index: Int)], deleteIds: Set<String>) {
        pendingDeleteTasks[operationID]?.cancel()
        bookmarks.pendingDeletionIds.subtract(deleteIds)
        // Ascending order, so each row lands at the index it was removed from.
        let sorted = removed.sorted { $0.index < $1.index }
        for item in sorted {
            bookmarks.bookmarks.insert(item.bookmark, at: min(item.index, bookmarks.bookmarks.count))
        }
        if let first = sorted.first {
            bookmarks.selectedBookmark = first.bookmark
            bookmarks.selectedIds = Set(sorted.map { $0.bookmark.id })
        }
        ui.dismissUndo()
        Task { await library?.loadBookmarks(showsLoadingIndicator: true) }
    }

    private func commitDelete(_ deleteIds: Set<String>) async {
        let allIds = Array(deleteIds)
        for start in stride(from: 0, to: allIds.count, by: Self.deleteChunkSize) {
            guard !Task.isCancelled else { return }
            let chunk = Set(allIds[start..<min(start + Self.deleteChunkSize, allIds.count)])
            do {
                try await api.deleteBookmarks(ids: chunk)
            } catch {
                ui.showError(String(localized: "Delete failed: \(error.localizedDescription)"))
            }
        }
        bookmarks.pendingDeletionIds.subtract(deleteIds)
        await library?.loadAll() // Full refresh to sync counts and lists
    }

    /// Prevent a deferred delete from being applied to a replacement library.
    func cancelPendingDeletes() async {
        let tasks = Array(pendingDeleteTasks.values)
        for task in tasks { task.cancel() }
        for task in tasks { await task.value }
        pendingDeleteTasks.removeAll()
        bookmarks.pendingDeletionIds.removeAll()
        ui.cancelUndoTimer()
        ui.undoGeneration += 1
        ui.undoAction = nil
        ui.undoMessage = nil
    }

    // MARK: - Trash

    /// Move bookmarks to the Trash directly (used by drag-to-trash in the
    /// sidebar). Removes them from the current view and refreshes counts.
    func trashBookmarks(ids: Set<String>) async {
        guard !ids.isEmpty else { return }
        do {
            try await api.deleteBookmarks(ids: ids)
            bookmarks.removeRows(ids)
            await refreshCounts()
        } catch { ui.showError(for: error) }
    }

    /// Restore bookmarks from the Trash; drop them from the current (trash) list.
    func restoreFromTrash(ids: Set<String>) async {
        do {
            _ = try await api.restoreFromTrash(ids: Array(ids))
            bookmarks.removeRows(ids)
            bookmarks.trashCount = max(0, bookmarks.trashCount - ids.count)
            await refreshCounts()
        } catch { ui.showError(for: error) }
    }

    // MARK: - Permanent delete

    /// Permanent deletes cannot be undone, so every entry point asks first.
    func requestEmptyTrash() {
        guard bookmarks.trashCount > 0 || !bookmarks.bookmarks.isEmpty else { return }
        pendingPurge = .all
    }

    func requestPurge(ids: Set<String>) {
        guard !ids.isEmpty else { return }
        pendingPurge = .ids(ids)
    }

    func confirmPendingPurge() {
        guard let pending = pendingPurge else { return }
        pendingPurge = nil
        Task {
            switch pending {
            case .all: await purge(ids: nil)
            case .ids(let ids): await purge(ids: ids)
            }
        }
    }

    func cancelPendingPurge() {
        pendingPurge = nil
    }

    /// Permanently delete trashed bookmarks (nil = empty the whole Trash).
    private func purge(ids: Set<String>?) async {
        do {
            _ = try await api.purgeTrash(ids: ids.map(Array.init))
            if let ids {
                bookmarks.removeRows(ids)
                bookmarks.trashCount = max(0, bookmarks.trashCount - ids.count)
            } else {
                bookmarks.bookmarks.removeAll()
                bookmarks.selectedIds.removeAll()
                bookmarks.selectedBookmark = nil
                bookmarks.trashCount = 0
            }
            await refreshCounts()
        } catch { ui.showError(for: error) }
    }

    func refreshCounts() async {
        guard let counts = try? await api.bookmarkCounts() else { return }
        bookmarks.applyCounts(counts)
    }
}
