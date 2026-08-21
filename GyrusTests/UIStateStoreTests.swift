import XCTest
@testable import Gyrus

@MainActor
final class UIStateStoreTests: XCTestCase {

    var store: UIStateStore!

    override func setUp() {
        super.setUp()
        store = UIStateStore()
    }

    func testShowInfoSetsMessageImmediately() {
        store.showInfo("Test Info")
        XCTAssertEqual(store.infoMessage, "Test Info")
    }

    func testShowInfoClearsMessageAfterDelay() async throws {
        store.showInfo("Test Info")
        XCTAssertEqual(store.infoMessage, "Test Info")

        // Wait slightly more than 3 seconds for the task to complete
        // 3_000_000_000 ns = 3 seconds
        try await Task.sleep(nanoseconds: 3_100_000_000)

        // The task should have cleared the message
        XCTAssertNil(store.infoMessage)
    }

    func testShowInfoCancelsPreviousTimer() async throws {
        store.showInfo("First Message")
        XCTAssertEqual(store.infoMessage, "First Message")

        // Wait 1.5 seconds
        try await Task.sleep(nanoseconds: 1_500_000_000)

        // Set a new message, which should cancel the previous 3-second timer
        store.showInfo("Second Message")
        XCTAssertEqual(store.infoMessage, "Second Message")

        // Wait another 2 seconds. Total time since first message is 3.5 seconds.
        // If the first timer wasn't cancelled, it would fire and clear the message now.
        try await Task.sleep(nanoseconds: 2_000_000_000)

        // The message should NOT be cleared yet, because the second timer still has 1 second left
        XCTAssertEqual(store.infoMessage, "Second Message")

        // Wait another 1.2 seconds so the second timer finishes (total 3.2s since second message)
        try await Task.sleep(nanoseconds: 1_200_000_000)

        XCTAssertNil(store.infoMessage)
    }

    func testDirectErrorCanBypassResumeGrace() {
        store.beginResumeGrace(10)
        store.showError("background")
        XCTAssertNil(store.errorMessage)

        store.showError("direct", respectingResumeGrace: false)
        XCTAssertEqual(store.errorMessage, "direct")
    }

    func testJobPollerStopsAfterRepeatedStatusFailures() async {
        struct TestStatus: JobStatusReporting { let running: Bool }
        enum TestError: Error { case unavailable }

        let poller = JobPoller<TestStatus>()
        let stopped = expectation(description: "poller reports repeated failure")
        var attempts = 0
        poller.start(
            interval: 0.001,
            fetch: {
                attempts += 1
                throw TestError.unavailable
            },
            onTick: { _ in },
            onFinished: { _ in },
            onError: { _ in stopped.fulfill() }
        )

        await fulfillment(of: [stopped], timeout: 1)
        XCTAssertEqual(attempts, 6)
    }
}
