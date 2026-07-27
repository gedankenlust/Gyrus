import Foundation
import Observation

@MainActor
@Observable
final class UIStateStore {
    var errorMessage: String? = nil
    var infoMessage: String? = nil
    var undoMessage: String? = nil
    private(set) var isLoading: Bool = false
    private(set) var isRefreshingBookmarks: Bool = false
    var undoAction: (() -> Void)? = nil
    var undoGeneration: Int = 0
    var linkCheckStatus: LinkCheckStatus? = nil
    var metadataRefreshStatus: MetadataRefreshStatus? = nil
    var batchAutoTagStatus: BatchAutoTagStatus? = nil
    var batchTagFailure: String? = nil

    // Batch selection for confirmations
    var pendingBatchDelete: Set<String>? = nil
    var pendingBatchOpen: Set<String>? = nil
    /// Bookmark ids awaiting a "New Tag" dialog. Presented from a stable parent
    /// (ContentView) because a sheet inside a context menu never shows.
    var newTagForIds: Set<String>? = nil
    /// Bookmark ids whose existing tags are being edited in the bulk tag sheet.
    var tagAssignmentForIds: Set<String>? = nil

    /// Tags the LLM created during the last batch auto-tag run, awaiting the
    /// keep/discard review sheet. Nil = nothing to review.
    var batchTagReview: TagReviewPayload? = nil

    private var errorTask: Task<Void, Never>?
    private var infoTask: Task<Void, Never>?
    private var undoTimerTask: Task<Void, Never>?
    @ObservationIgnored private var loadingOperations = 0
    @ObservationIgnored private var bookmarkRefreshOperations = 0

    /// While the app is returning from sleep / regaining focus, in-flight
    /// requests can briefly fail (404/5xx/connection) before the backend has
    /// reconnected. Error toasts are swallowed until this moment passes.
    private var suppressErrorsUntil: Date = .distantPast

    func beginLoading() {
        loadingOperations += 1
        isLoading = true
    }

    func endLoading() {
        loadingOperations = max(0, loadingOperations - 1)
        isLoading = loadingOperations > 0
    }

    func beginBookmarkRefresh() {
        bookmarkRefreshOperations += 1
        isRefreshingBookmarks = true
    }

    func endBookmarkRefresh() {
        bookmarkRefreshOperations = max(0, bookmarkRefreshOperations - 1)
        isRefreshingBookmarks = bookmarkRefreshOperations > 0
    }

    /// Start a short window during which transient error toasts are suppressed.
    /// Called when the app becomes active or the Mac wakes.
    func beginResumeGrace(_ seconds: TimeInterval = 4) {
        suppressErrorsUntil = Date().addingTimeInterval(seconds)
        errorMessage = nil   // clear anything already on screen
        errorTask?.cancel()
    }

    // MARK: - Toasts

    func showError(_ message: String) {
        // Don't alarm the user with transient failures right after resume.
        if Date() < suppressErrorsUntil { return }
        errorMessage = message
        errorTask?.cancel()
        errorTask = Task {
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled else { return }
            errorMessage = nil
        }
    }

    func showInfo(_ message: String) {
        infoMessage = message
        infoTask?.cancel()
        infoTask = Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled else { return }
            infoMessage = nil
        }
    }

    func startUndoTimer(window: TimeInterval) {
        undoTimerTask?.cancel()
        undoTimerTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(window * 1_000_000_000))
            guard !Task.isCancelled else { return }
            undoMessage = nil
            undoAction = nil
        }
    }

    func cancelUndoTimer() {
        undoTimerTask?.cancel()
    }
}
