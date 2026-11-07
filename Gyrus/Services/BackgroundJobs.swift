import Foundation
import Observation

/// The parts of the library a finished background job or a committed delete
/// needs to refresh. AppStore conforms; tests substitute a recorder.
@MainActor
protocol LibraryReloading: AnyObject {
    func loadAll() async
    func loadBookmarks(showsLoadingIndicator: Bool) async
}

/// The four long-running backend jobs (link check, metadata refresh, folder
/// organize, taxonomy review), their published progress, and what happens
/// when each one finishes. The pollers live with the app, not with a view,
/// so a job keeps reporting after the window or Settings that started it closes.
@MainActor
@Observable
final class BackgroundJobs {
    /// A taxonomy needs shared categories (each backed by ≥2 bookmarks);
    /// below this the run is guaranteed to fail. Mirrors the backend's
    /// MIN_TAXONOMY_BOOKMARKS in auto_tag_batch_service.py.
    static let minTaxonomyBookmarks = 10

    var linkCheckStatus: LinkCheckStatus?
    var metadataRefreshStatus: MetadataRefreshStatus?
    var folderOrganizeStatus: FolderOrganizeStatus?
    var batchAutoTagStatus: BatchAutoTagStatus?
    var batchTagFailure: String?
    /// The shared tag system the last taxonomy run drafted, awaiting the
    /// keep/discard review sheet. Nil = nothing to review.
    var batchTagReview: TagReviewPayload?

    /// Set by the owner once it is fully initialized; weak because the owner
    /// also owns this object.
    @ObservationIgnored weak var library: LibraryReloading?

    @ObservationIgnored private let api: APIClient
    @ObservationIgnored private let ui: UIStateStore
    @ObservationIgnored private let bookmarks: BookmarkStore
    @ObservationIgnored private let aiConfig: @MainActor () -> AIBrainConfig
    @ObservationIgnored private let linkCheckPoller = JobPoller<LinkCheckStatus>()
    @ObservationIgnored private let metadataPoller = JobPoller<MetadataRefreshStatus>()
    @ObservationIgnored private let batchTagPoller = JobPoller<BatchAutoTagStatus>()
    @ObservationIgnored private let folderOrganizePoller = JobPoller<FolderOrganizeStatus>()

    init(api: APIClient,
         ui: UIStateStore,
         bookmarks: BookmarkStore,
         aiConfig: @escaping @MainActor () -> AIBrainConfig = { AppSettings.shared.aiBrainConfig }) {
        self.api = api
        self.ui = ui
        self.bookmarks = bookmarks
        self.aiConfig = aiConfig
    }

    /// These jobs must not report into a replacement library. The folder
    /// sort's poller keeps running, as it always has, and reloads the library
    /// itself when the job ends.
    func stopForLibraryReplacement() {
        linkCheckPoller.stop()
        metadataPoller.stop()
        batchTagPoller.stop()
    }

    func resetLocalState() {
        batchTagReview = nil
        linkCheckStatus = nil
        metadataRefreshStatus = nil
        batchAutoTagStatus = nil
    }

    // MARK: - Link Check

    func startLinkCheck() async {
        do {
            linkCheckStatus = try await api.startLinkCheck()
            linkCheckPoller.start(
                interval: 1.5,
                fetch: { [api] in try await api.linkCheckStatus() },
                onTick: { [weak self] status in self?.linkCheckStatus = status },
                onFinished: { [weak self] _ in await self?.finishLinkCheck() },
                onError: { [weak self] error in
                    self?.linkCheckStatus = nil
                    self?.ui.showError(for: error)
                }
            )
        } catch {
            ui.showError(for: error)
        }
    }

    /// The last tick already published the final status; refresh what the
    /// check can change (dead count, dead badges in the list).
    func finishLinkCheck() async {
        if let dead = try? await api.deadBookmarkCount() {
            bookmarks.deadBookmarkCount = dead
        }
        await library?.loadBookmarks(showsLoadingIndicator: true)
    }

    // MARK: - Metadata Refresh

    /// Force a re-fetch of favicons, descriptions and preview images for every
    /// bookmark (heals broken/stale metadata). Runs in the background and polls
    /// for progress, then reloads the list so the new favicons appear.
    func startMetadataRefresh() async {
        guard metadataRefreshStatus?.running != true else { return }
        do {
            metadataRefreshStatus = try await api.startMetadataRefresh()
            metadataPoller.start(
                interval: 1.0,
                fetch: { [api] in try await api.metadataRefreshStatus() },
                onTick: { [weak self] status in self?.metadataRefreshStatus = status },
                onFinished: { [weak self] status in await self?.finishMetadataRefresh(status) },
                onError: { [weak self] error in
                    self?.metadataRefreshStatus = nil
                    self?.ui.showError(for: error)
                }
            )
        } catch {
            ui.showError(for: error)
        }
    }

    func finishMetadataRefresh(_ status: MetadataRefreshStatus) async {
        // Bust cached favicon images (same filename → same URL) so the
        // freshly fetched icons actually show, then reload.
        URLCache.shared.removeAllCachedResponses()
        FaviconCache.shared.clear()
        await library?.loadBookmarks(showsLoadingIndicator: true)
        if let error = status.error, !error.isEmpty {
            ui.showError(error)
        } else if let failed = status.failed, failed > 0 {
            ui.showInfo(String(localized: "Updated \(status.updated) bookmarks; \(failed) pages returned no metadata."))
        } else if status.updated > 0 {
            ui.showInfo(String(localized: "Updated \(status.updated) bookmarks."))
        }
    }

    /// Ask the backend to stop the metadata refresh. Already-fetched data is kept.
    func cancelMetadataRefresh() async {
        do {
            metadataRefreshStatus = try await api.cancelMetadataRefresh()
        } catch {
            ui.showError(for: error)
        }
    }

    // MARK: - Folder Organize

    /// The folder sort keeps running after Settings closes. This poller lives
    /// with the app, and the sidebar reloads when the move finishes.
    func startFolderOrganize() async {
        guard folderOrganizeStatus?.running != true else { return }
        do {
            folderOrganizeStatus = try await api.startFolderOrganize(config: aiConfig())
            folderOrganizePoller.start(
                interval: 2.0,
                fetch: { [api] in try await api.folderOrganizeStatus() },
                onTick: { [weak self] status in self?.folderOrganizeStatus = status },
                onFinished: { [weak self] status in await self?.finishFolderOrganize(status) }
            )
        } catch {
            ui.showError(for: error)
        }
    }

    func finishFolderOrganize(_ status: FolderOrganizeStatus) async {
        folderOrganizeStatus = status
        if status.phase == "done" || status.phase == "error" || status.phase == "moving" {
            await library?.loadAll()
        }
    }

    func cancelFolderOrganize() async {
        folderOrganizeStatus = try? await api.cancelFolderOrganize()
    }

    // MARK: - Taxonomy Review (batch auto-tag)

    /// Build one shared, reviewable tag system for a selection. This is the
    /// slower AI path and never writes tags until the user approves the draft.
    func startTaxonomyReview(ids: [String]) async {
        guard batchAutoTagStatus?.running != true else { return }
        guard ids.count >= Self.minTaxonomyBookmarks else {
            ui.showError(String(localized: "Select at least \(Self.minTaxonomyBookmarks) bookmarks to build a tag system."))
            return
        }
        let config = aiConfig()
        guard config.aiEnabled else {
            ui.showError(String(localized: "Enable AI to review a tag system."))
            return
        }
        do {
            batchTagFailure = nil
            batchAutoTagStatus = try await api.startBatchAutoTag(ids: ids, config: config)
            ui.showInfo(String(localized: "Analyzing \(ids.count) bookmarks…"))
            batchTagPoller.start(
                interval: 1.5,
                fetch: { [api] in try await api.batchAutoTagStatus() },
                onTick: { [weak self] status in self?.batchAutoTagStatus = status },
                onFinished: { [weak self] status in self?.finishTaxonomyReview(status) },
                onError: { [weak self] error in
                    guard let self else { return }
                    self.batchAutoTagStatus = nil
                    self.batchTagFailure = error.localizedDescription
                    self.ui.showError(for: error)
                }
            )
        } catch {
            batchAutoTagStatus = nil
            ui.showError(for: error)
        }
    }

    func finishTaxonomyReview(_ status: BatchAutoTagStatus) {
        batchAutoTagStatus = nil
        if let draft = status.draft {
            batchTagReview = TagReviewPayload(draft: draft)
        } else if let error = status.error?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !error.isEmpty {
            batchTagFailure = error
        } else if status.phase != "cancelled" {
            batchTagFailure = String(localized: "No tag system could be created.")
        }
    }

    func cancelBatchAutoTag() async {
        batchTagPoller.stop()
        _ = try? await api.cancelBatchAutoTag()
        batchAutoTagStatus = nil
        ui.showInfo(String(localized: "Analysis stopped. No tags were changed."))
    }
}
