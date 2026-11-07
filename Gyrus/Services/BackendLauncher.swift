import Foundation
import Observation

@MainActor
@Observable
final class BackendLauncher {
    static let shared = BackendLauncher()

    var isRunning = false
    var isBootstrapping = false
    var bootstrapStatus = ""
    var error: String?

    private var process: Process?
    private var logHandle: FileHandle?
    private var isStarting = false
    private var isStopping = false
    private var setupProcess: Process?

    /// `Gyrus.app/Contents/Resources/backend` when this process is the app bundle.
    private var bundledBackendDirectory: URL? {
        Bundle.main.resourceURL?.appendingPathComponent("backend")
    }

    /// Source-tree backend next to this file: `<repo>/backend`.
    private var repoBackendDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("backend")
    }

    /// Dev interpreter lives in `<repo>/backend/venv`, not under a name that
    /// merely contains that substring.
    private var projectVenvDirectory: URL {
        repoBackendDirectory.appendingPathComponent("venv")
    }

    private var backendDir: URL {
        let repo = repoBackendDirectory

        // Built and installed apps must exercise the exact backend they ship.
        // Xcode users can explicitly opt into the faster repo venv when needed.
        if ProcessInfo.processInfo.environment["GYRUS_USE_REPO_BACKEND"] == "1",
           FileManager.default.fileExists(atPath: repo.appendingPathComponent("main.py").path) {
            return repo
        }

        if let bundlePath = bundledBackendDirectory,
           FileManager.default.fileExists(atPath: bundlePath.appendingPathComponent("main.py").path) {
            return bundlePath
        }

        // Source-tree fallback for unusual command-line development builds.
        return repo
    }

    private let dataDir: URL = {
        let app = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return app.appendingPathComponent("Gyrus")
    }()

    private var pidFile: URL { dataDir.appendingPathComponent("backend.pid") }

    /// A distributed app's Resources are read-only, so its Python venv must live
    /// in a writable location. In dev we keep it next to the source (unchanged).
    private var isBundledBackend: Bool { backendDir.path.contains(".app/Contents/Resources") }
    private var venvDir: URL {
        isBundledBackend ? dataDir.appendingPathComponent("backend-venv")
                         : backendDir.appendingPathComponent("venv")
    }
    private var venvPython: URL { venvDir.appendingPathComponent("bin/python") }

    /// A self-contained Python runtime bundled with the app (built by
    /// `backend/build_python_runtime.sh`). When present, the app needs NO system
    /// Python, venv or pip — it launches straight from this on any Mac.
    private var bundledRuntimePython: URL? {
        let py = backendDir.appendingPathComponent("python-runtime/bin/python3")
        return FileManager.default.fileExists(atPath: py.path) ? py : nil
    }

    /// The interpreter to run the backend with. Bundled apps use their exact
    /// self-contained runtime; repo development can opt in via the environment.
    private var usesBundledRuntime: Bool { isBundledBackend && bundledRuntimePython != nil }
    private var pythonExecutable: URL {
        if usesBundledRuntime, let runtime = bundledRuntimePython {
            return runtime
        }
        return venvPython
    }

    private init() {}

    func clearLog() {
        if let logHandle {
            do {
                try logHandle.seek(toOffset: 0)
                try logHandle.truncate(atOffset: 0)
            } catch {
                // Reset already succeeded; a diagnostic log must not make it fail.
            }
        }
        let bootstrapLog = dataDir.appendingPathComponent("backend-bootstrap.log")
        try? Data().write(to: bootstrapLog, options: .atomic)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: bootstrapLog.path
        )
    }

    /// Stop the backend a previous launch left behind (Xcode Stop, a crash, a
    /// different copy of the app). The pid file records pid, start time and
    /// executable, so a recycled pid never matches and the check does not depend
    /// on the interpreter path, which differs between venv symlinks, DMG mounts
    /// and installed copies.
    private func killExistingBackend() async -> Bool {
        guard let data = try? Data(contentsOf: pidFile),
              let contents = String(data: data, encoding: .utf8) else { return true }

        if let record = BackendProcessRecord(serialized: contents) {
            guard record.isAlive else {
                try? FileManager.default.removeItem(at: pidFile)
                return true
            }
            let stopped = await terminate(pid: record.pid) { record.isAlive }
            if stopped { try? FileManager.default.removeItem(at: pidFile) }
            return stopped
        }

        // Pid files written before 1.5.2 hold only the pid.
        if let pid = Int32(contents.trimmingCharacters(in: .whitespacesAndNewlines)),
           isGyrusBackend(pid: pid) {
            let stopped = await terminate(pid: pid) { [self] in isGyrusBackend(pid: pid) }
            if !stopped { return false }
        }
        try? FileManager.default.removeItem(at: pidFile)
        return true
    }

    /// SIGTERM, then SIGKILL if the process ignores it. A backend hung in a
    /// long call must not block every later launch with "still stopping".
    private func terminate(pid: Int32, isAlive: () -> Bool) async -> Bool {
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
        let path = String(cString: buffer)
        if path == pythonExecutable.path { return true }
        if let bundled = bundledBackendDirectory, pathIsInside(path, bundled) {
            return true
        }
        return pathIsInside(path, projectVenvDirectory)
    }

    /// True when `path` is the directory or a file inside it. A trailing
    /// separator keeps `/tmp/Gyrus/backend/venv/fake` from matching a real venv.
    private func pathIsInside(_ path: String, _ directory: URL) -> Bool {
        let root = directory.path
        guard !root.isEmpty else { return false }
        if path == root { return true }
        let prefix = root.hasSuffix("/") ? root : root + "/"
        return path.hasPrefix(prefix)
    }

    nonisolated static let apiToken = UUID().uuidString

    func start() async {
        // SwiftUI can restart the scene task when StartupView is replaced by
        // ContentView. Never let that second call kill the healthy backend that
        // the first call has just launched.
        guard !isStopping else { return }
        if isRunning, (try? await APIClient.shared.health()) == true {
            return
        }
        guard !isStarting, !isStopping else { return }
        isStarting = true
        isRunning = false
        error = nil
        defer { isStarting = false }

        try? FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dataDir.path)
        guard await killExistingBackend() else {
            error = String(localized: "The previous backend is still stopping. Please try again.")
            return
        }
        // Anything that still answers the health check now is a Gyrus backend
        // this launch does not own (another copy of the app, a test run). Its
        // token differs, so every request would fail with 401 and the library
        // would look empty. Say so instead of starting a second one.
        if (try? await APIClient.shared.health()) == true {
            error = String(localized: "Another copy of Gyrus is already using port 8080. Quit it (or stop the Xcode run) and try again.")
            return
        }

        guard !isStopping, !Task.isCancelled else { return }

        // With a bundled runtime there's nothing to set up — skip the
        // venv/pip bootstrap entirely (no system Python needed). Otherwise
        // fall back to building a venv from the system Python (dev machines).
        if !usesBundledRuntime {
            do {
                try await bootstrapIfNeeded()
            } catch {
                self.error = "Setup failed:\n\(error.localizedDescription)"
                return
            }
        }

        guard !isStopping, !Task.isCancelled else { return }
        let python = pythonExecutable
        guard FileManager.default.fileExists(atPath: python.path) else {
            error = "Backend not found at:\n\(backendDir.path)\n\nPython environment missing."
            return
        }

        let proc = Process()
        proc.executableURL = python
        proc.arguments = [
            "-m", "uvicorn", "main:app",
            "--host", Config.backendHost,
            "--port", String(Config.backendPort),
            "--log-level", "warning"
        ]
        proc.currentDirectoryURL = backendDir
        var environment = ProcessInfo.processInfo.environment
        environment["GYRUS_API_TOKEN"] = Self.apiToken
        // The backend exits on its own when this process disappears, so a
        // crash or an Xcode Stop cannot leave an orphan holding the port.
        environment["GYRUS_PARENT_PID"] = String(ProcessInfo.processInfo.processIdentifier)
        if usesBundledRuntime {
            environment["PLAYWRIGHT_BROWSERS_PATH"] = backendDir
                .appendingPathComponent("python-runtime/playwright-browsers").path
            // Never let Python create __pycache__ inside the signed app bundle.
            // Keep bytecode caching, but redirect it to writable app support.
            environment["PYTHONPYCACHEPREFIX"] = dataDir
                .appendingPathComponent("python-cache").path
        }
        proc.environment = environment
        let logURL = dataDir.appendingPathComponent("backend.log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: logURL.path)
        try? logHandle?.close()
        logHandle = nil
        if let handle = try? FileHandle(forWritingTo: logURL) {
            try? handle.truncate(atOffset: 0)
            proc.standardOutput = handle
            proc.standardError = handle
            logHandle = handle
        }

        do {
            proc.terminationHandler = { [weak self] ended in
                Task { @MainActor in
                    guard let self, self.process === ended, !self.isStarting else { return }
                    self.isRunning = false
                    self.error = String(localized: "The backend stopped. Please try again.")
                }
            }
            try proc.run()
            self.process = proc
            let record = BackendProcessRecord.live(pid: proc.processIdentifier)
            let pidContents = record?.serialized ?? String(proc.processIdentifier)
            try? pidContents.write(to: pidFile, atomically: true, encoding: .utf8)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: pidFile.path)
        } catch {
            self.error = "Failed to start: \(error.localizedDescription)"
            return
        }

        // Poll up to 15s
        for _ in 0..<30 {
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !isStopping, !Task.isCancelled else { return }
            guard proc.isRunning else {
                error = startupFailureMessage(logURL: logURL)
                return
            }
            if (try? await APIClient.shared.health()) == true, proc.isRunning {
                isRunning = true
                return
            }
        }
        error = "Backend did not respond.\nPath: \(backendDir.path)"
    }

    /// Explain an early exit from what the backend actually logged, instead
    /// of blaming the port for every failure (a migration error looks the same
    /// from the outside).
    private func startupFailureMessage(logURL: URL) -> String {
        let tail = Self.logTail(at: logURL)
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

    private static func logTail(at url: URL, maxBytes: UInt64 = 4096) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > maxBytes ? size - maxBytes : 0)
        let data = (try? handle.readToEnd()) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    func stopAndWait() async {
        isStopping = true
        if setupProcess?.isRunning == true { setupProcess?.terminate() }
        guard let child = process else { stop(); return }
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
        process?.terminationHandler = nil
        if process?.isRunning == true { process?.terminate() }
        try? logHandle?.close()
        logHandle = nil
        try? FileManager.default.removeItem(at: pidFile)
        process = nil
        isRunning = false
    }

    private func bootstrapIfNeeded() async throws {
        if FileManager.default.fileExists(atPath: venvPython.path) {
            return
        }

        isBootstrapping = true
        defer { isBootstrapping = false }

        try? FileManager.default.createDirectory(at: venvDir.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        let bootstrapLog = dataDir.appendingPathComponent("backend-bootstrap.log")
        FileManager.default.createFile(atPath: bootstrapLog.path, contents: nil)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: bootstrapLog.path
        )

        bootstrapStatus = "Creating virtual environment..."
        try await runCommand(executable: "/usr/bin/python3", arguments: ["-m", "venv", venvDir.path], currentDirectory: backendDir)

        bootstrapStatus = "Installing dependencies..."
        try await runCommand(executable: venvPython.path, arguments: ["-m", "pip", "install", "--require-hashes", "-r", "requirements.lock"], currentDirectory: backendDir)

        bootstrapStatus = "Running migrations..."
        try await runCommand(executable: venvPython.path, arguments: ["-m", "alembic", "upgrade", "head"], currentDirectory: backendDir)
    }

    private func runCommand(executable: String, arguments: [String], currentDirectory: URL) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = currentDirectory

        let logURL = dataDir.appendingPathComponent("backend-bootstrap.log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        guard let output = try? FileHandle(forWritingTo: logURL) else {
            throw NSError(
                domain: "BackendLauncher",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Could not open the backend setup log."]
            )
        }
        defer { try? output.close() }
        try output.seekToEnd()
        let commandLine = "\n$ \(([executable] + arguments).joined(separator: " "))\n"
        try output.write(contentsOf: Data(commandLine.utf8))
        process.standardOutput = output
        process.standardError = output

        guard !isStopping else { throw CancellationError() }
        try process.run()
        setupProcess = process
        defer { setupProcess = nil }

        let deadline = ContinuousClock.now.advanced(by: .seconds(15 * 60))
        while process.isRunning {
            if isStopping || Task.isCancelled {
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
                            "Backend setup timed out. Details: \(logURL.path)"
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
                        "Backend setup failed with status \(process.terminationStatus). Details: \(logURL.path)"
                ]
            )
        }
    }
}

/// Identity of a launched backend: pid plus kernel start time. A pid alone can
/// be recycled by an unrelated process after the backend exits.
struct BackendProcessRecord: Equatable {
    let pid: Int32
    let startSeconds: UInt64
    let startMicroseconds: UInt64
    let executable: String

    var serialized: String {
        "\(pid)\n\(startSeconds).\(startMicroseconds)\n\(executable)"
    }

    init(pid: Int32, startSeconds: UInt64, startMicroseconds: UInt64, executable: String) {
        self.pid = pid
        self.startSeconds = startSeconds
        self.startMicroseconds = startMicroseconds
        self.executable = executable
    }

    init?(serialized: String) {
        let lines = serialized.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard lines.count >= 3,
              let pid = Int32(lines[0].trimmingCharacters(in: .whitespaces)) else { return nil }
        let start = lines[1].split(separator: ".")
        guard start.count == 2,
              let seconds = UInt64(start[0]), let micros = UInt64(start[1]) else { return nil }
        let executable = lines[2...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !executable.isEmpty else { return nil }
        self.init(pid: pid, startSeconds: seconds, startMicroseconds: micros, executable: executable)
    }

    /// Reads the running process's start time and executable from the kernel.
    static func live(pid: Int32) -> BackendProcessRecord? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.stride)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        var buffer = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return BackendProcessRecord(
            pid: pid,
            startSeconds: info.pbi_start_tvsec,
            startMicroseconds: info.pbi_start_tvusec,
            executable: String(cString: buffer)
        )
    }

    /// True while the very process this record describes is still running.
    var isAlive: Bool {
        BackendProcessRecord.live(pid: pid) == self
    }
}
