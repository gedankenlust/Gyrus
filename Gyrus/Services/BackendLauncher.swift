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

    private var backendDir: URL {
        let bundled = Bundle.main.resourceURL?.appendingPathComponent("backend")
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("backend")

        // Built and installed apps must exercise the exact backend they ship.
        // Xcode users can explicitly opt into the faster repo venv when needed.
        if ProcessInfo.processInfo.environment["GYRUS_USE_REPO_BACKEND"] == "1",
           FileManager.default.fileExists(atPath: repo.appendingPathComponent("main.py").path) {
            return repo
        }

        if let bundlePath = bundled,
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

    private func killExistingBackend() {
        // Kill by PID file if available (precise)
        if let data = try? Data(contentsOf: pidFile),
           let pidStr = String(data: data, encoding: .utf8),
           let pid = Int32(pidStr.trimmingCharacters(in: .whitespacesAndNewlines)) {
            kill(pid, SIGTERM)
            try? FileManager.default.removeItem(at: pidFile)
        }
        // Also kill any process holding port 8080. A stale PID file can point
        // to one backend while another old listener still owns the port.
        killPortHolder(Config.backendPort)
    }

    private func killPortHolder(_ port: Int) {
        let lsof = Process()
        lsof.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        lsof.arguments = ["-ti", "tcp:\(port)"]
        let pipe = Pipe()
        lsof.standardOutput = pipe
        lsof.standardError = Pipe()
        guard (try? lsof.run()) != nil else { return }
        lsof.waitUntilExit()
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        for line in output.components(separatedBy: .newlines) {
            if let pid = Int32(line.trimmingCharacters(in: .whitespaces)) {
                kill(pid, SIGTERM)
            }
        }
    }

    func start() async {
        try? FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
        killExistingBackend()
        try? await Task.sleep(nanoseconds: 800_000_000)

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
        if usesBundledRuntime {
            environment["PLAYWRIGHT_BROWSERS_PATH"] = backendDir
                .appendingPathComponent("python-runtime/playwright-browsers").path
        }
        proc.environment = environment
        let logURL = dataDir.appendingPathComponent("backend.log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        if let handle = try? FileHandle(forWritingTo: logURL) {
            try? handle.truncate(atOffset: 0)
            proc.standardOutput = handle
            proc.standardError = handle
            logHandle = handle
        }

        do {
            try proc.run()
            self.process = proc
            try? String(proc.processIdentifier).write(to: pidFile, atomically: true, encoding: .utf8)
        } catch {
            self.error = "Failed to start: \(error.localizedDescription)"
            return
        }

        // Poll up to 15s
        for _ in 0..<30 {
            try? await Task.sleep(nanoseconds: 500_000_000)
            if (try? await APIClient.shared.health()) == true {
                isRunning = true
                return
            }
        }
        error = "Backend did not respond.\nPath: \(backendDir.path)"
    }

    func stop() {
        process?.terminate()
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

        bootstrapStatus = "Creating virtual environment..."
        try await runCommand(executable: "/usr/bin/python3", arguments: ["-m", "venv", venvDir.path], currentDirectory: backendDir)

        bootstrapStatus = "Installing dependencies..."
        try await runCommand(executable: venvPython.path, arguments: ["-m", "pip", "install", "-r", "requirements.txt"], currentDirectory: backendDir)

        bootstrapStatus = "Running migrations..."
        try await runCommand(executable: venvPython.path, arguments: ["-m", "alembic", "upgrade", "head"], currentDirectory: backendDir)
    }

    private func runCommand(executable: String, arguments: [String], currentDirectory: URL) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = currentDirectory

        // Capture output to avoid polluting terminal or getting blocked by full pipes
        process.standardOutput = Pipe()
        process.standardError = Pipe()

        try process.run()

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            process.terminationHandler = { _ in
                continuation.resume()
            }
        }

        if process.terminationStatus != 0 {
            throw NSError(domain: "BackendLauncher", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: "Command failed with status \(process.terminationStatus)"])
        }
    }
}
