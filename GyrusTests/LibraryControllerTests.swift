import XCTest
@testable import Gyrus

/// Background jobs, connection recovery and AppStore composition.
@MainActor
final class LibraryControllerTests: XCTestCase {
    override func tearDown() {
        ControllerURLProtocol.handler = nil
        super.tearDown()
    }

    // MARK: - Background jobs

    func testFolderOrganizeFinishUpdatesStatusAndReloadsLibrary() async throws {
        let (jobs, _, _, library) = makeJobs { _ in (500, Data()) }
        let done: FolderOrganizeStatus = try decodeFixture(#"{"running":false,"phase":"done","processed":3,"total":3}"#)
        await jobs.finishFolderOrganize(done)
        XCTAssertEqual(jobs.folderOrganizeStatus?.phase, "done")
        XCTAssertEqual(library.loadAllCount, 1)

        // A cancelled sort changed nothing, so nothing is reloaded.
        let cancelled: FolderOrganizeStatus = try decodeFixture(#"{"running":false,"phase":"cancelled"}"#)
        await jobs.finishFolderOrganize(cancelled)
        XCTAssertEqual(jobs.folderOrganizeStatus?.phase, "cancelled")
        XCTAssertEqual(library.loadAllCount, 1)
    }

    func testFinishedLinkCheckPublishesStatusRefreshesDeadCountAndReloads() async throws {
        let (jobs, bookmarks, _, library) = makeJobs { request in
            switch request.url!.path {
            case "/api/bookmarks/check-links":
                return (200, Data(#"{"running":true,"checked":0,"total":2,"dead_found":0}"#.utf8))
            case "/api/bookmarks/check-links/status":
                return (200, Data(#"{"running":false,"checked":2,"total":2,"dead_found":1}"#.utf8))
            case "/api/bookmarks/count-dead":
                return (200, Data("4".utf8))
            default:
                XCTFail("Unexpected request \(request.url!.path)")
                return (404, Data())
            }
        }
        let reloaded = expectation(description: "List reloaded after the check")
        library.onLoadBookmarks = { reloaded.fulfill() }

        await jobs.startLinkCheck()
        XCTAssertEqual(jobs.linkCheckStatus?.running, true)
        await fulfillment(of: [reloaded], timeout: 5)

        XCTAssertEqual(jobs.linkCheckStatus?.running, false)
        XCTAssertEqual(jobs.linkCheckStatus?.deadFound, 1)
        XCTAssertEqual(bookmarks.deadBookmarkCount, 4)
    }

    func testTaxonomyFinishReportsFailureButNotCancellation() throws {
        let (jobs, _, _, _) = makeJobs { _ in (500, Data()) }
        jobs.finishTaxonomyReview(try decodeFixture(#"{"running":false,"processed":1,"total":12,"phase":"error","error":"  Model unavailable \n"}"#))
        XCTAssertEqual(jobs.batchTagFailure, "Model unavailable")
        XCTAssertNil(jobs.batchAutoTagStatus)

        jobs.batchTagFailure = nil
        jobs.finishTaxonomyReview(try decodeFixture(#"{"running":false,"processed":1,"total":12,"phase":"cancelled"}"#))
        XCTAssertNil(jobs.batchTagFailure)
        XCTAssertNil(jobs.batchTagReview)
    }

    func testTaxonomyReviewNeedsEnoughBookmarksAndAI() async {
        var config = AIBrainConfig()
        config.aiEnabled = false
        let (jobs, _, ui, _) = makeJobs(aiConfig: config) { _ in
            XCTFail("No request may be sent")
            return (500, Data())
        }
        await jobs.startTaxonomyReview(ids: ["a"])
        XCTAssertNotNil(ui.errorMessage)
        ui.errorMessage = nil
        await jobs.startTaxonomyReview(ids: (0..<BackgroundJobs.minTaxonomyBookmarks).map { "b-\($0)" })
        XCTAssertNotNil(ui.errorMessage)
        XCTAssertNil(jobs.batchAutoTagStatus)
    }

    // MARK: - Connection recovery

    func testHealthyRecoveryDoesNotStartResumeGrace() async {
        let (monitor, ui, restarts) = makeMonitor(health: [true])
        ui.showError("A user's failed delete")

        await monitor.recoverConnection()

        // The earlier toast stays, and background errors are not muted.
        XCTAssertEqual(ui.errorMessage, "A user's failed delete")
        ui.showError("background", respectingResumeGrace: true)
        XCTAssertEqual(ui.errorMessage, "background")
        XCTAssertEqual(restarts(), 0)
    }

    func testResumeGraceStartsAfterFirstFailedHealthCheck() async {
        let (monitor, ui, restarts) = makeMonitor(health: [false, true])
        ui.showError("stale")

        await monitor.recoverConnection()

        XCTAssertNil(ui.errorMessage, "Starting the grace clears what is on screen")
        ui.showError("background", respectingResumeGrace: true)
        XCTAssertNil(ui.errorMessage)
        ui.showError("direct")
        XCTAssertEqual(ui.errorMessage, "direct")
        XCTAssertEqual(restarts(), 0, "A backend that answers on a retry is not restarted")
    }

    func testUnreachableBackendIsRestartedAfterFourChecks() async {
        let (monitor, _, restarts) = makeMonitor(health: [false, false, false, false])
        await monitor.recoverConnection()
        XCTAssertEqual(restarts(), 1)
    }

    // MARK: - Composition

    func testAppStoreHandsItselfToItsControllers() {
        let app = AppStore(api: stubbedClient { _ in (500, Data()) }, draftStorage: nil)
        XCTAssertTrue(app.jobs.library === app)
        XCTAssertTrue(app.trash.library === app)
        XCTAssertTrue(app.connection.library === app)
    }

    // MARK: - Fixtures

    private func makeJobs(
        aiConfig: AIBrainConfig = AIBrainConfig(),
        _ handler: @escaping (URLRequest) throws -> (Int, Data)
    ) -> (BackgroundJobs, BookmarkStore, UIStateStore, LibraryRecorder) {
        let api = stubbedClient(handler)
        let bookmarks = BookmarkStore(api: api, draftStorage: nil)
        let ui = UIStateStore()
        let library = LibraryRecorder()
        let jobs = BackgroundJobs(api: api, ui: ui, bookmarks: bookmarks, aiConfig: { aiConfig })
        jobs.library = library
        return (jobs, bookmarks, ui, library)
    }

    /// A monitor whose health checks answer `health` in order; restarting the
    /// backend is recorded and reported as failed, so nothing is launched.
    private func makeMonitor(health: [Bool]) -> (ConnectionMonitor, UIStateStore, () -> Int) {
        let answers = HealthAnswers(health)
        let api = stubbedClient { request in
            XCTAssertEqual(request.url?.path, "/api/ready")
            return answers.next()
                ? (200, Data(#"{"status":"ok","service":"gyrus"}"#.utf8))
                : (503, Data())
        }
        let bookmarks = BookmarkStore(api: api, draftStorage: nil)
        let ui = UIStateStore()
        var restarts = 0
        let monitor = ConnectionMonitor(
            api: api, ui: ui, bookmarks: bookmarks,
            jobs: BackgroundJobs(api: api, ui: ui, bookmarks: bookmarks),
            configSync: AIConfigSync { _ in },
            aiConfig: { AIBrainConfig() },
            effects: .init(restartBackend: { restarts += 1; return false }, refreshFavicons: {})
        )
        return (monitor, ui, { restarts })
    }
}
