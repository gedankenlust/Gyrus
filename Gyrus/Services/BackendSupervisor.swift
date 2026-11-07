import Foundation

/// The backend process itself, without any UI state: the pid file, finding
/// and stopping a backend an earlier launch left behind, the setup commands,
/// spawning uvicorn with its environment, the log, termination and the
/// startup-failure diagnosis. `BackendLauncher` owns the observable state and
/// decides the order of these steps.
///
/// The async methods are nonisolated, so their file reads, process spawns and
/// polling loops run on the cooperative pool, never on the main actor that
/// calls them. The little shared state sits behind a lock because `stop()` and
/// the termination check stay synchronous for the launcher.
final class BackendSupervisor: @unchecked Sendable {
    enum LaunchError: LocalizedError {
        case interpreterMissing(backendDirectory: URL)

        var errorDescription: String? {
            switch self {
            case .interpreterMissing(let directory):
                return String(localized: "Backend not found at:\n\(directory.path)\n\nPython environment missing.")
            }
        }
    }

    /// What a pid file can hold.
    enum PidFileContents: Equatable {
        case record(BackendProcessRecord)
        /// Pid files written before 1.5.2 hold only the pid.
        case legacyPID(Int32)
        case unrecognized
    }

    /// The venv bootstrap for machines without the bundled runtime.
    enum SetupStep: CaseIterable {
        case createVirtualEnvironment
        case installDependencies
        case runMigrations
    }

    let layout: BackendLayout

    private let lock = NSLock()
    private var process: Process?
    private var logHandle: FileHandle?
    private var setupProcess: Process?
    private var stopRequested = false

    init(layout: BackendLayout = .standard) {
        self.layout = layout
    }

    /// Lock-guarded access to the mutable state. Synchronous on purpose: the
    /// lock is never held across a suspension point.
    private func locked<Result>(_ body: () throws -> Result) rethrows -> Result {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    // MARK: - Pure parts

    static func parsePidFile(_ contents: String) -> PidFileContents {
        if let record = BackendProcessRecord(serialized: contents) { return .record(record) }
        if let pid = Int32(contents.trimmingCharacters(in: .whitespacesAndNewlines)) { return .legacyPID(pid) }
        return .unrecognized
    }

    static let uvicornArguments = [
        "-m", "uvicorn", "main:app",
        "--host", Config.backendHost,
        "--port", String(Config.backendPort),
        "--log-level", "warning"
    ]

    /// The backend's environment: the app's own plus the session token, the
    /// parent pid and, for the bundled runtime, its cache locations.
    static func environment(inheriting inherited: [String: String], token: String, parentPID: Int32,
                            usesBundledRuntime: Bool, backendDirectory: URL,
                            dataDirectory: URL) -> [String: String] {
        var environment = inherited
        environment["GYRUS_API_TOKEN"] = token
        // The backend exits on its own when this process disappears, so a
        // crash or an Xcode Stop cannot leave an orphan holding the port.
        environment["GYRUS_PARENT_PID"] = String(parentPID)
        if usesBundledRuntime {
            environment["PLAYWRIGHT_BROWSERS_PATH"] = backendDirectory
                .appendingPathComponent("python-runtime/playwright-browsers").path
            // Never let Python create __pycache__ inside the signed app bundle.
            // Keep bytecode caching, but redirect it to writable app support.
            environment["PYTHONPYCACHEPREFIX"] = dataDirectory
                .appendingPathComponent("python-cache").path
        }
        return environment
    }

    /// Explain an early exit from what the backend actually logged, instead
    /// of blaming the port for every failure (a migration error looks the same
    /// from the outside).
    static func diagnoseStartupFailure(logTail tail: String) -> String {
        if tail.contains("address already in use") || tail.contains("Errno 48") {
            return String(localized: "The backend could not start because another program is using port 8080.")
        }
        let lastLine = tail
            .split(whereSeparator: \.isNewline)
            .last { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .map(String.init)
        guard let lastLine else {
            return String(localized: "The backend stopped during startup.")
        }
        return String(localized: "The backend stopped during startup.") + "\n" + String(lastLine.prefix(300))
    }

    static func command(for step: SetupStep, layout: BackendLayout) -> (executable: String, arguments: [String]) {
        switch step {
        case .createVirtualEnvironment:
            return ("/usr/bin/python3", ["-m", "venv", layout.venvDirectory.path])
        case .installDependencies:
            return (layout.venvPython.path, ["-m", "pip", "install", "--require-hashes", "-r", "requirements.lock"])
        case .runMigrations:
            return (layout.venvPython.path, ["-m", "alembic", "upgrade", "head"])
        }
    }

    /// The last `maxBytes` of a log file, decoded leniently.
    static func logTail(at url: URL, maxBytes: UInt64 = 4096) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > maxBytes ? size - maxBytes : 0)
        let data = (try? handle.readToEnd()) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - Data directory and leftovers

    func prepareDataDirectory() async {
        let directory = layout.dataDirectory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }

    /// Stop the backend a previous launch left behind (Xcode Stop, a crash, a
    /// different copy of the app). The pid file records pid, start time and
    /// executable, so a recycled pid never matches and the check does not depend
    /// on the interpreter path, which differs between venv symlinks, DMG mounts
    /// and installed copies. False when it is still running after SIGKILL.
    func terminateLeftoverBackend() async -> Bool {
        let pidFile = layout.pidFile
        guard let data = try? Data(contentsOf: pidFile),
              let contents = String(data: data, encoding: .utf8) else { return true }

        switch Self.parsePidFile(contents) {
        case .record(let record):
            guard record.isAlive else {
                try? FileManager.default.removeItem(at: pidFile)
                return true
            }
            let stopped = await Self.terminate(pid: record.pid) { record.isAlive }
            if stopped { try? FileManager.default.removeItem(at: pidFile) }
            return stopped
        case .legacyPID(let pid):
            if isGyrusBackend(pid: pid) {
                let stopped = await Self.terminate(pid: pid) { isGyrusBackend(pid: pid) }
                if !stopped { return false }
            }
        case .unrecognized:
            break
        }
        try? FileManager.default.removeItem(at: pidFile)
        return true
    }

    /// SIGTERM, then SIGKILL if the process ignores it. A backend hung in a
    /// long call must not block every later launch with "still stopping".
    private static func terminate(pid: Int32, isAlive: () -> Bool) async -> Bool {
        kill(pid, SIGTERM)
        for _ in 0..<50 {
            if !isAlive() { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        kill(pid, SIGKILL)
        for _ in 0..<20 {
            if !isAlive() { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return !isAlive()
    }

    private func isGyrusBackend(pid: Int32) -> Bool {
        // proc_pidpath recommends a MAXPATHLEN-sized buffer; use generous fixed
        // storage because the C macro is not imported into Swift.
        var buffer = [CChar](repeating: 0, count: 4096)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return false }
        return layout.isBackendExecutable(String(cString: buffer))
    }

    // MARK: - Setup

    /// True when the backend needs a venv built from the system Python. With
    /// a bundled runtime there's nothing to set up (no system Python needed).
    func needsVirtualEnvironment() async -> Bool {
        !layout.usesBundledRuntime && !FileManager.default.fileExists(atPath: layout.venvPython.path)
    }

    func prepareSetupLog() async {
        try? FileManager.default.createDirectory(at: layout.venvDirectory.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        let setupLog = layout.setupLogFile
        FileManager.default.createFile(atPath: setupLog.path, contents: nil)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: setupLog.path)
    }

    func run(_ step: SetupStep) async throws {
        let (executable, arguments) = Self.command(for: step, layout: layout)
        try await runSetupCommand(executable: executable, arguments: arguments,
                                  currentDirectory: layout.backendDirectory)
    }

    private func runSetupCommand(executable: String, arguments: [String], currentDirectory: URL) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = currentDirectory

        let logURL = layout.setupLogFile
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        guard let output = try? FileHandle(forWritingTo: logURL) else {
            throw NSError(
                domain: "BackendLauncher",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: String(localized: "Could not open the backend setup log.")]
            )
        }
        defer { try? output.close() }
        try output.seekToEnd()
        let commandLine = "\n$ \(([executable] + arguments).joined(separator: " "))\n"
        try output.write(contentsOf: Data(commandLine.utf8))
        process.standardOutput = output
        process.standardError = output

        guard !isStopRequested else { throw CancellationError() }
        try process.run()
        locked { setupProcess = process }
        defer { locked { setupProcess = nil } }

        let deadline = ContinuousClock.now.advanced(by: .seconds(15 * 60))
        while process.isRunning {
            if isStopRequested || Task.isCancelled {
                process.terminate()
                throw CancellationError()
            }
            if ContinuousClock.now >= deadline {
                process.terminate()
                throw NSError(
                    domain: "BackendLauncher",
                    code: 2,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            String(localized: "Backend setup timed out. Details: \(logURL.path)")
                    ]
                )
            }
            try await Task.sleep(for: .milliseconds(200))
        }

        if process.terminationStatus != 0 {
            throw NSError(
                domain: "BackendLauncher",
                code: Int(process.terminationStatus),
                userInfo: [
                    NSLocalizedDescriptionKey:
                        String(localized: "Backend setup failed with status \(process.terminationStatus). Details: \(logURL.path)")
                ]
            )
        }
    }

    // MARK: - Backend process

    /// Spawn uvicorn, log to `backend.log` and record its identity in the pid
    /// file. `onExit` fires on a background thread with the identity of the
    /// process that ended; check it with `isCurrentProcess` before acting,
    /// because `stop()` may have replaced or cleared it meanwhile. Returns the
    /// backend directory it started in, for diagnostics.
    func launch(token: String, onExit: @escaping @Sendable (ObjectIdentifier) -> Void) async throws -> URL {
        let backendDirectory = layout.backendDirectory
        let python = layout.pythonExecutable
        guard FileManager.default.fileExists(atPath: python.path) else {
            throw LaunchError.interpreterMissing(backendDirectory: backendDirectory)
        }

        let proc = Process()
        proc.executableURL = python
        proc.arguments = Self.uvicornArguments
        proc.currentDirectoryURL = backendDirectory
        proc.environment = Self.environment(
            inheriting: ProcessInfo.processInfo.environment,
            token: token,
            parentPID: ProcessInfo.processInfo.processIdentifier,
            usesBundledRuntime: layout.usesBundledRuntime,
            backendDirectory: backendDirectory,
            dataDirectory: layout.dataDirectory
        )
        let logURL = layout.logFile
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: logURL.path)
        let previousHandle = locked {
            defer { logHandle = nil }
            return logHandle
        }
        try? previousHandle?.close()
        let handle = try? FileHandle(forWritingTo: logURL)
        if let handle {
            try? handle.truncate(atOffset: 0)
            proc.standardOutput = handle
            proc.standardError = handle
        }
        locked { logHandle = handle }

        proc.terminationHandler = { ended in onExit(ObjectIdentifier(ended)) }
        try proc.run()
        locked { process = proc }
        let record = BackendProcessRecord.live(pid: proc.processIdentifier)
        let pidContents = record?.serialized ?? String(proc.processIdentifier)
        let pidFile = layout.pidFile
        try? pidContents.write(to: pidFile, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: pidFile.path)
        return backendDirectory
    }

    var isBackendRunning: Bool {
        locked { process?.isRunning == true }
    }

    func isCurrentProcess(_ identity: ObjectIdentifier) -> Bool {
        locked { process.map(ObjectIdentifier.init) == identity }
    }

    func startupFailureMessage() async -> String {
        Self.diagnoseStartupFailure(logTail: Self.logTail(at: layout.logFile))
    }

    // MARK: - Stopping

    private var isStopRequested: Bool { locked { stopRequested } }

    /// The app is quitting: abort a running setup command and refuse new ones.
    func requestStop() {
        let setup = locked {
            stopRequested = true
            return setupProcess
        }
        if setup?.isRunning == true { setup?.terminate() }
    }

    /// SIGTERM, five seconds, SIGKILL, then `stop()`. The waiting happens off
    /// the main actor so quitting never stalls the UI.
    func stopAndWait() async {
        guard let child = locked({ process }) else { stop(); return }
        child.terminationHandler = nil
        if child.isRunning { child.terminate() }
        for _ in 0..<50 {
            if !child.isRunning { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        if child.isRunning { kill(child.processIdentifier, SIGKILL) }
        for _ in 0..<20 {
            if !child.isRunning { break }
            try? await Task.sleep(for: .milliseconds(50))
        }
        stop()
    }

    func stop() {
        let (child, handle) = locked {
            defer { process = nil; logHandle = nil }
            return (process, logHandle)
        }
        child?.terminationHandler = nil
        if child?.isRunning == true { child?.terminate() }
        try? handle?.close()
        try? FileManager.default.removeItem(at: layout.pidFile)
    }

    /// Empty both logs, e.g. after a factory reset. The running backend keeps
    /// writing to its handle, which now starts from the beginning.
    func clearLog() async {
        locked {
            guard let logHandle else { return }
            do {
                try logHandle.seek(toOffset: 0)
                try logHandle.truncate(atOffset: 0)
            } catch {
                // Reset already succeeded; a diagnostic log must not make it fail.
            }
        }
        let setupLog = layout.setupLogFile
        try? Data().write(to: setupLog, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: setupLog.path)
    }
}
