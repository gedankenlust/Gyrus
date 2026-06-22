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
    var batchAutoTagStatus: BatchAutoTagStatus? = nil

    // Batch selection for confirmations
    var pendingBatchDelete: Set<String>? = nil
    var pendingBatchOpen: Set<String>? = nil
    /// Bookmark ids awaiting a "New Tag" dialog. Presented from a stable parent
    /// (ContentView) because a sheet inside a context menu never shows.
    var newTagForIds: Set<String>? = nil

    private var errorTask: Task<Void, Never>?
    private var infoTask: Task<Void, Never>?
    private var undoTimerTask: Task<Void, Never>?

    /// While the app is returning from sleep / regaining focus, in-flight
    /// requests can briefly fail (404/5xx/connection) before the backend has
    /// reconnected. Error toasts are swallowed until this moment passes.
    private var suppressErrorsUntil: Date = .distantPast

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
