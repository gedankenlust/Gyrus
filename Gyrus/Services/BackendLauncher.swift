import Foundation
import Observation

/// The backend state the UI binds to (`isRunning`, `isBootstrapping`,
/// `bootstrapStatus`, `error`) and the order of a launch: leftover cleanup,
/// port check, venv bootstrap, spawn, health wait. The process work itself
/// lives in `BackendSupervisor`, off the main actor.
@MainActor
@Observable
final class BackendLauncher {
    static let shared = BackendLauncher()

    var isRunning = false
    var isBootstrapping = false
    var bootstrapStatus = ""
    var error: String?

    private let supervisor: BackendSupervisor
    private var isStarting = false
    private var isStopping = false

    nonisolated static let apiToken = UUID().uuidString

    private init(supervisor: BackendSupervisor = BackendSupervisor()) {
        self.supervisor = supervisor
    }

    /// Truncates the logs in the background; nothing waits for it.
    func clearLog() {
        let supervisor = supervisor
        Task { await supervisor.clearLog() }
    }

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

        await supervisor.prepareDataDirectory()
        guard await supervisor.terminateLeftoverBackend() else {
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
        if await supervisor.needsVirtualEnvironment() {
            do {
                try await bootstrap()
            } catch {
                self.error = String(localized: "Setup failed:\n\(error.localizedDescription)")
                return
            }
        }

        guard !isStopping, !Task.isCancelled else { return }
        let backendDirectory: URL
        do {
            backendDirectory = try await supervisor.launch(token: Self.apiToken) { [weak self] ended in
                Task { @MainActor in
                    guard let self, self.supervisor.isCurrentProcess(ended), !self.isStarting else { return }
                    self.isRunning = false
                    self.error = String(localized: "The backend stopped. Please try again.")
                }
            }
        } catch let launchError as BackendSupervisor.LaunchError {
            error = launchError.localizedDescription
            return
        } catch {
            self.error = String(localized: "Failed to start: \(error.localizedDescription)")
            return
        }

        // Poll up to 15s
        for _ in 0..<30 {
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !isStopping, !Task.isCancelled else { return }
            guard supervisor.isBackendRunning else {
                error = await supervisor.startupFailureMessage()
                return
            }
            if (try? await APIClient.shared.health()) == true, supervisor.isBackendRunning {
                isRunning = true
                return
            }
        }
        error = String(localized: "Backend did not respond.\nPath: \(backendDirectory.path)")
    }

    func stopAndWait() async {
        isStopping = true
        supervisor.requestStop()
        await supervisor.stopAndWait()
        isRunning = false
    }

    func stop() {
        supervisor.stop()
        isRunning = false
    }

    private func bootstrap() async throws {
        isBootstrapping = true
        defer { isBootstrapping = false }

        await supervisor.prepareSetupLog()

        bootstrapStatus = String(localized: "Creating virtual environment...")
        try await supervisor.run(.createVirtualEnvironment)

        bootstrapStatus = String(localized: "Installing dependencies...")
        try await supervisor.run(.installDependencies)

        bootstrapStatus = String(localized: "Running migrations...")
        try await supervisor.run(.runMigrations)
    }
}
