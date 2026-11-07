import Foundation

/// Where the backend, its interpreter and its runtime files live. The fixed
/// roots are captured once; everything that depends on what is installed is
/// computed on access, as it always was, so a venv created by the bootstrap is
/// picked up by the launch that follows it.
struct BackendLayout: Sendable {
    /// `Gyrus.app/Contents/Resources/backend` when this process is the app bundle.
    let bundledBackendDirectory: URL?
    /// Source-tree backend next to the Swift sources: `<repo>/backend`.
    let repoBackendDirectory: URL
    /// `~/Library/Application Support/Gyrus`: pid file, logs, writable venv.
    let dataDirectory: URL
    /// Xcode users can explicitly opt into the faster repo venv when needed.
    let prefersRepoBackend: Bool

    static let standard = BackendLayout(
        bundledBackendDirectory: Bundle.main.resourceURL?.appendingPathComponent("backend"),
        repoBackendDirectory: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("backend"),
        dataDirectory: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Gyrus"),
        prefersRepoBackend: ProcessInfo.processInfo.environment["GYRUS_USE_REPO_BACKEND"] == "1"
    )

    /// Dev interpreter lives in `<repo>/backend/venv`, not under a name that
    /// merely contains that substring.
    var projectVenvDirectory: URL { repoBackendDirectory.appendingPathComponent("venv") }

    var backendDirectory: URL {
        let fileManager = FileManager.default
        // Built and installed apps must exercise the exact backend they ship.
        if prefersRepoBackend,
           fileManager.fileExists(atPath: repoBackendDirectory.appendingPathComponent("main.py").path) {
            return repoBackendDirectory
        }
        if let bundledBackendDirectory,
           fileManager.fileExists(atPath: bundledBackendDirectory.appendingPathComponent("main.py").path) {
            return bundledBackendDirectory
        }
        // Source-tree fallback for unusual command-line development builds.
        return repoBackendDirectory
    }

    var pidFile: URL { dataDirectory.appendingPathComponent("backend.pid") }
    var logFile: URL { dataDirectory.appendingPathComponent("backend.log") }
    var setupLogFile: URL { dataDirectory.appendingPathComponent("backend-bootstrap.log") }

    /// A distributed app's Resources are read-only, so its Python venv must live
    /// in a writable location. In dev we keep it next to the source (unchanged).
    var isBundledBackend: Bool { backendDirectory.path.contains(".app/Contents/Resources") }
    var venvDirectory: URL {
        isBundledBackend ? dataDirectory.appendingPathComponent("backend-venv")
                         : backendDirectory.appendingPathComponent("venv")
    }
    var venvPython: URL { venvDirectory.appendingPathComponent("bin/python") }

    /// A self-contained Python runtime bundled with the app (built by
    /// `backend/build_python_runtime.sh`). When present, the app needs NO system
    /// Python, venv or pip — it launches straight from this on any Mac.
    var bundledRuntimePython: URL? {
        let python = backendDirectory.appendingPathComponent("python-runtime/bin/python3")
        return FileManager.default.fileExists(atPath: python.path) ? python : nil
    }

    /// The interpreter to run the backend with. Bundled apps use their exact
    /// self-contained runtime; repo development can opt in via the environment.
    var usesBundledRuntime: Bool { isBundledBackend && bundledRuntimePython != nil }
    var pythonExecutable: URL {
        if usesBundledRuntime, let runtime = bundledRuntimePython {
            return runtime
        }
        return venvPython
    }

    /// Whether an executable path belongs to a backend some copy of Gyrus
    /// started: this layout's interpreter, anything inside the app's bundled
    /// backend, or the repo venv. Used only for pid files that predate
    /// `BackendProcessRecord`, so an unrelated process with a recycled pid is
    /// never killed.
    func isBackendExecutable(_ path: String) -> Bool {
        if path == pythonExecutable.path { return true }
        if let bundledBackendDirectory, Self.path(path, isInside: bundledBackendDirectory) {
            return true
        }
        return Self.path(path, isInside: projectVenvDirectory)
    }

    /// True when `path` is the directory or a file inside it. A trailing
    /// separator keeps `/tmp/Gyrus/backend/venv/fake` from matching a real venv.
    static func path(_ path: String, isInside directory: URL) -> Bool {
        let root = directory.path
        guard !root.isEmpty else { return false }
        if path == root { return true }
        let prefix = root.hasSuffix("/") ? root : root + "/"
        return path.hasPrefix(prefix)
    }
}
