import Foundation
import Observation

@MainActor
@Observable
final class UIStateStore {
    var errorMessage: String? = nil
    var infoMessage: String? = nil
    var undoMessage: String? = nil
    var isLoading: Bool = false
    var undoAction: (() -> Void)? = nil
    var undoGeneration: Int = 0
    var linkCheckStatus: LinkCheckStatus? = nil
    var metadataRefreshStatus: MetadataRefreshStatus? = nil

    // Batch selection for confirmations
    var pendingBatchDelete: Set<String>? = nil
    var pendingBatchOpen: Set<String>? = nil
    /// Bookmark ids awaiting a "New Tag" dialog. Presented from a stable parent
    /// (ContentView) because a sheet inside a context menu never shows.
    var newTagForIds: Set<String>? = nil

    private var errorTask: Task<Void, Never>?
    private var infoTask: Task<Void, Never>?
    private var undoTimerTask: Task<Void, Never>?

    // MARK: - Toasts

    func showError(_ message: String) {
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
