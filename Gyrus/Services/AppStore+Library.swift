import Foundation

// MARK: - Resets: clearing local state when the library is replaced

extension AppStore {
    /// Forget everything shown for the old library. Called after the server
    /// side was cleared or restored, between prepare/finishLibraryReplacement.
    func resetLocalLibraryState() {
        BrainChatStore.shared.resetLocalState()
        bookmarksStore.resetLocalState()
        collectionsStore.resetLocalState()
        collectionsStore.selectedCollectionId = nil
        collectionsStore.showTrash = false
        collectionsStore.showDeadOnly = false
        collectionsStore.showUnreadOnly = false
        tagsStore.resetLocalState()
        tagsStore.selectedTagName = nil
        trash.pendingBatchDelete = nil
        jobs.resetLocalState()
        uiStateStore.resetLocalState()
        loadError = nil
    }

    enum ResetType: String {
        case cache, brain, bookmarks, factory
    }

    func handleReset(type: ResetType) async throws {
        if type == .bookmarks || type == .factory { await prepareForLibraryReplacement() }
        defer { finishLibraryReplacement() }
        do {
            switch type {
            case .cache:
                try await api.clearCache()
                FaviconCache.shared.refresh()
            case .brain:
                try await api.clearBrain()
            case .bookmarks:
                try await api.clearBookmarks()
                resetLocalLibraryState()
            case .factory:
                try await api.factoryReset()
                BackendLauncher.shared.clearLog()
                resetLocalLibraryState()
                AppSettings.shared.resetToDefaults()
                await AIConfigSync.shared.synchronize(AppSettings.shared.aiBrainConfig, force: true)
            }
            await loadAll()
        } catch {
            await loadAll()
            throw error
        }
    }
}
