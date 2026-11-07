import XCTest
@testable import Gyrus

/// The supervisor's pure parts and its file handling against a throwaway
/// layout. Nothing here spawns a backend, touches port 8080 or the real
/// Application Support folder, or signals a process.
final class BackendSupervisorTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("BackendSupervisorTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func layout(bundled: URL? = nil, prefersRepo: Bool = false) -> BackendLayout {
        BackendLayout(bundledBackendDirectory: bundled,
                      repoBackendDirectory: root.appendingPathComponent("repo/backend"),
                      dataDirectory: root.appendingPathComponent("data"),
                      prefersRepoBackend: prefersRepo)
    }

    private func touch(_ url: URL, _ contents: String = "") throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url)
    }

    // MARK: Startup failure diagnosis

    func testPortInUseIsRecognizedFromTheLog() {
        let expected = String(localized: "The backend could not start because another program is using port 8080.")
        XCTAssertEqual(BackendSupervisor.diagnoseStartupFailure(logTail: "ERROR: [Errno 48] address already in use"), expected)
        XCTAssertEqual(BackendSupervisor.diagnoseStartupFailure(logTail: "OSError: Errno 48"), expected)
    }

    func testOtherFailuresQuoteTheLastLoggedLine() {
        let message = BackendSupervisor.diagnoseStartupFailure(
            logTail: "Traceback\n  File x\nalembic.util.exc.CommandError: Can't locate revision\n\n   \n")
        XCTAssertEqual(message, String(localized: "The backend stopped during startup.")
                       + "\nalembic.util.exc.CommandError: Can't locate revision")
    }

    func testEmptyLogGivesThePlainMessageAndLongLinesAreCut() {
        XCTAssertEqual(BackendSupervisor.diagnoseStartupFailure(logTail: " \n\n"),
                       String(localized: "The backend stopped during startup."))
        let long = String(repeating: "x", count: 1000)
        let message = BackendSupervisor.diagnoseStartupFailure(logTail: long)
        XCTAssertEqual(message.split(separator: "\n").last?.count, 300)
    }

    func testLogTailReadsOnlyTheEnd() throws {
        let log = root.appendingPathComponent("backend.log")
        try touch(log, String(repeating: "a", count: 5000) + "TAIL")
        let tail = BackendSupervisor.logTail(at: log, maxBytes: 10)
        XCTAssertEqual(tail, "aaaaaaTAIL")
        XCTAssertEqual(BackendSupervisor.logTail(at: root.appendingPathComponent("missing.log")), "")
    }

    func testStartupFailureMessageReadsTheLayoutsLog() async throws {
        let layout = layout()
        try touch(layout.logFile, "starting\nRuntimeError: database is locked\n")
        let message = await BackendSupervisor(layout: layout).startupFailureMessage()
        XCTAssertTrue(message.hasSuffix("RuntimeError: database is locked"))
    }

    // MARK: Environment and command lines

    func testEnvironmentAddsTokenAndParentAndKeepsInherited() {
        let environment = BackendSupervisor.environment(
            inheriting: ["PATH": "/usr/bin", "GYRUS_API_TOKEN": "stale"], token: "secret", parentPID: 4242,
            usesBundledRuntime: false, backendDirectory: root, dataDirectory: root)
        XCTAssertEqual(environment["PATH"], "/usr/bin")
        XCTAssertEqual(environment["GYRUS_API_TOKEN"], "secret")
        XCTAssertEqual(environment["GYRUS_PARENT_PID"], "4242")
        XCTAssertNil(environment["PLAYWRIGHT_BROWSERS_PATH"])
        XCTAssertNil(environment["PYTHONPYCACHEPREFIX"])
    }

    func testBundledRuntimeRedirectsBrowsersAndBytecode() {
        let backend = URL(fileURLWithPath: "/Applications/Gyrus.app/Contents/Resources/backend")
        let data = URL(fileURLWithPath: "/tmp/gyrus-data")
        let environment = BackendSupervisor.environment(
            inheriting: [:], token: "t", parentPID: 1, usesBundledRuntime: true,
            backendDirectory: backend, dataDirectory: data)
        XCTAssertEqual(environment["PLAYWRIGHT_BROWSERS_PATH"], backend.path + "/python-runtime/playwright-browsers")
        XCTAssertEqual(environment["PYTHONPYCACHEPREFIX"], "/tmp/gyrus-data/python-cache")
    }

    func testUvicornListensOnTheConfiguredLoopbackPort() {
        let arguments = BackendSupervisor.uvicornArguments
        XCTAssertEqual(Array(arguments.prefix(3)), ["-m", "uvicorn", "main:app"])
        XCTAssertEqual(arguments[arguments.firstIndex(of: "--host")! + 1], "127.0.0.1")
        XCTAssertEqual(arguments[arguments.firstIndex(of: "--port")! + 1], "8080")
    }

    func testSetupCommandsUseTheLayoutsVenv() {
        let layout = layout()
        let venv = BackendSupervisor.command(for: .createVirtualEnvironment, layout: layout)
        XCTAssertEqual(venv.executable, "/usr/bin/python3")
        XCTAssertEqual(venv.arguments, ["-m", "venv", layout.venvDirectory.path])
        let pip = BackendSupervisor.command(for: .installDependencies, layout: layout)
        XCTAssertEqual(pip.executable, layout.venvPython.path)
        XCTAssertTrue(pip.arguments.contains("--require-hashes"))
        XCTAssertEqual(BackendSupervisor.command(for: .runMigrations, layout: layout).arguments,
                       ["-m", "alembic", "upgrade", "head"])
    }

    // MARK: Pid file

    func testPidFileParsing() {
        let record = BackendProcessRecord(pid: 7, startSeconds: 1, startMicroseconds: 2, executable: "/bin/python")
        XCTAssertEqual(BackendSupervisor.parsePidFile(record.serialized), .record(record))
        XCTAssertEqual(BackendSupervisor.parsePidFile(" 4242\n"), .legacyPID(4242))
        XCTAssertEqual(BackendSupervisor.parsePidFile("garbage"), .unrecognized)
        XCTAssertEqual(BackendSupervisor.parsePidFile(""), .unrecognized)
    }

    func testNoPidFileMeansNothingToStop() async {
        let stopped = await BackendSupervisor(layout: layout()).terminateLeftoverBackend()
        XCTAssertTrue(stopped)
    }

    func testStaleRecordIsRemovedWithoutSignalling() async throws {
        // This very process with a different start time: the pid matches, the
        // identity does not, so it must be treated as gone (and not signalled).
        let live = try XCTUnwrap(BackendProcessRecord.live(pid: getpid()))
        let stale = BackendProcessRecord(pid: live.pid, startSeconds: live.startSeconds - 60,
                                         startMicroseconds: live.startMicroseconds, executable: live.executable)
        let layout = layout()
        try touch(layout.pidFile, stale.serialized)
        let stopped = await BackendSupervisor(layout: layout).terminateLeftoverBackend()
        XCTAssertTrue(stopped)
        XCTAssertFalse(FileManager.default.fileExists(atPath: layout.pidFile.path))
    }

    func testUnrecognizedPidFileIsRemoved() async throws {
        let layout = layout()
        try touch(layout.pidFile, "not a pid")
        let stopped = await BackendSupervisor(layout: layout).terminateLeftoverBackend()
        XCTAssertTrue(stopped)
        XCTAssertFalse(FileManager.default.fileExists(atPath: layout.pidFile.path))
    }

    func testStopWithoutProcessRemovesPidFile() throws {
        let layout = layout()
        try touch(layout.pidFile, "1")
        let supervisor = BackendSupervisor(layout: layout)
        XCTAssertFalse(supervisor.isBackendRunning)
        supervisor.stop()
        XCTAssertFalse(FileManager.default.fileExists(atPath: layout.pidFile.path))
    }

    func testClearLogEmptiesTheSetupLog() async throws {
        let layout = layout()
        try touch(layout.setupLogFile, "pip output")
        await BackendSupervisor(layout: layout).clearLog()
        XCTAssertEqual(try Data(contentsOf: layout.setupLogFile).count, 0)
    }

    // MARK: Layout

    func testBundledBackendWinsAndKeepsItsVenvInAppSupport() throws {
        let bundled = root.appendingPathComponent("Gyrus.app/Contents/Resources/backend")
        try touch(bundled.appendingPathComponent("main.py"))
        let layout = layout(bundled: bundled)
        XCTAssertEqual(layout.backendDirectory, bundled)
        XCTAssertTrue(layout.isBundledBackend)
        XCTAssertEqual(layout.venvDirectory, layout.dataDirectory.appendingPathComponent("backend-venv"))
        XCTAssertFalse(layout.usesBundledRuntime)
        try touch(bundled.appendingPathComponent("python-runtime/bin/python3"))
        XCTAssertTrue(layout.usesBundledRuntime)
        XCTAssertEqual(layout.pythonExecutable, bundled.appendingPathComponent("python-runtime/bin/python3"))
    }

    func testRepoBackendOnlyWhenRequestedAndPresent() throws {
        let bundled = root.appendingPathComponent("Gyrus.app/Contents/Resources/backend")
        try touch(bundled.appendingPathComponent("main.py"))
        XCTAssertEqual(layout(bundled: bundled, prefersRepo: true).backendDirectory, bundled)
        try touch(root.appendingPathComponent("repo/backend/main.py"))
        let repo = layout(bundled: bundled, prefersRepo: true)
        XCTAssertEqual(repo.backendDirectory, repo.repoBackendDirectory)
        XCTAssertFalse(repo.isBundledBackend)
        XCTAssertEqual(repo.venvDirectory, repo.repoBackendDirectory.appendingPathComponent("venv"))
    }

    func testBackendExecutableMatchesOnlyInsideKnownDirectories() {
        let bundled = root.appendingPathComponent("Gyrus.app/Contents/Resources/backend")
        let layout = layout(bundled: bundled)
        XCTAssertTrue(layout.isBackendExecutable(bundled.path + "/python-runtime/bin/python3"))
        XCTAssertTrue(layout.isBackendExecutable(layout.projectVenvDirectory.path + "/bin/python3.12"))
        XCTAssertFalse(layout.isBackendExecutable(layout.projectVenvDirectory.path + "-fake/bin/python"))
        XCTAssertFalse(layout.isBackendExecutable("/usr/bin/python3"))
        XCTAssertFalse(BackendLayout.path("/a/bc", isInside: URL(fileURLWithPath: "/a/b")))
        XCTAssertTrue(BackendLayout.path("/a/b", isInside: URL(fileURLWithPath: "/a/b")))
    }
}
