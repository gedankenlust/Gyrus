import Foundation
import Observation

/// Keeps the window in step with the backend: a periodic poll that reloads
/// when the server's bookmark count drifts from ours, and recovery after the
/// Mac wakes or the app returns to the foreground.
@MainActor
@Observable
final class ConnectionMonitor {
    /// The process-level effects of a recovery, injectable so tests never
    /// restart the real backend or reach its port.
    struct Effects {
        /// Start the backend again; true once it is running.
        var restartBackend: @MainActor () async -> Bool
        var refreshFavicons: @MainActor () -> Void

        static var live: Effects {
            Effects(
                restartBackend: {
                    await BackendLauncher.shared.start()
                    return BackendLauncher.shared.isRunning
                },
                refreshFavicons: { FaviconCache.shared.refresh() }
            )
        }
    }

    /// Set by the owner once it is fully initialized; weak because the owner
    /// also owns this object.
    @ObservationIgnored weak var library: LibraryReloading?

    @ObservationIgnored private let api: APIClient
    @ObservationIgnored private let ui: UIStateStore
    @ObservationIgnored private let bookmarks: BookmarkStore
    @ObservationIgnored private let jobs: BackgroundJobs
    @ObservationIgnored private let configSync: AIConfigSync
    @ObservationIgnored private let aiConfig: @MainActor () -> AIBrainConfig
    @ObservationIgnored private let effects: Effects
    @ObservationIgnored private var autoRefreshTask: Task<Void, Never>?
    @ObservationIgnored private var isRecovering = false

    init(api: APIClient,
         ui: UIStateStore,
         bookmarks: BookmarkStore,
         jobs: BackgroundJobs,
         configSync: AIConfigSync? = nil,
         aiConfig: @escaping @MainActor () -> AIBrainConfig = { AppSettings.shared.aiBrainConfig },
         effects: Effects = .live) {
        self.api = api
        self.ui = ui
        self.bookmarks = bookmarks
        self.jobs = jobs
        self.configSync = configSync ?? .shared
        self.aiConfig = aiConfig
        self.effects = effects
    }

    // MARK: - Auto-refresh

    func startAutoRefreshPolling() {
        guard autoRefreshTask == nil else { return }
        autoRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000) // poll every 5 seconds
                guard !Task.isCancelled, let self else { return }
                await self.autoRefreshTick()
            }
        }
    }

    func stopAutoRefreshPolling() {
        autoRefreshTask?.cancel()
        autoRefreshTask = nil
    }

    private func autoRefreshTick() async {
        // Skip while we're actively loading, recovering the backend
        // (wake-from-sleep), or running a link check — otherwise the
        // poll can race the reconnect and surface a transient 404.
        guard !ui.isLoading, !isRecovering, jobs.linkCheckStatus?.running != true else { return }

        do {
            // Active enrichment changes no bookmark count, so refresh
            // the visible rows while work is pending to keep their
            // durable status indicators current.
            if bookmarks.bookmarks.contains(where: { $0.analysis?.isActive == true }) {
                try? await bookmarks.refreshLoadedRows()
            }
            let serverCount = try await api.bookmarkCount()
            let localTotal = bookmarks.totalBookmarkCount + bookmarks.pendingDeletionIds.count
            if serverCount != localTotal {
                await library?.loadAll()
            }
        } catch {
            // Ignore background-polling errors.
        }

        if configSync.error != nil {
            configSync.submit(aiConfig())
        }
        // Re-check semantic availability if Ollama wasn't ready at startup.
        if !bookmarks.semanticSearchAvailable {
            await bookmarks.refreshSemanticSearchStatus()
        }
    }

    // MARK: - Recovery

    /// Called when the app returns to the foreground or the Mac wakes from
    /// sleep. The backend (a child process) can become unreachable across sleep,
    /// which also makes favicons fall back to the globe. Re-check the backend,
    /// restart it if needed, and refresh the UI so icons come back.
    func recoverConnection() async {
        guard !isRecovering else { return }
        isRecovering = true
        defer { isRecovering = false }

        // Right after wake-from-sleep the backend can be momentarily slow to
        // answer (its process was suspended). Retry the lightweight health
        // check a few times before concluding it must be restarted — otherwise
        // we needlessly kill a perfectly alive backend, and that restart window
        // is exactly what produced the transient "Server error 404".
        var healthy = false
        for attempt in 0..<4 {
            if (try? await api.health()) == true { healthy = true; break }
            // Only mute background error toasts once the backend actually
            // fails to answer. A healthy resume must not hide the result of a
            // user's action (a failed delete would just silently reappear).
            if attempt == 0 { ui.beginResumeGrace(8) }
            if attempt < 3 { try? await Task.sleep(nanoseconds: 500_000_000) }
        }

        if !healthy {
            guard await effects.restartBackend() else { return }
            await configSync.synchronize(aiConfig(), force: true)
            await library?.loadAll()
            // A real restart briefly failed in-flight requests; keep them muted
            // a moment longer now that the backend is back up.
            ui.beginResumeGrace(3)
        }
        await configSync.synchronize(aiConfig())
        effects.refreshFavicons()
    }
}
