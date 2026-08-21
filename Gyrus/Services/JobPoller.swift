import Foundation

/// Status payload of a pollable backend background job (see backend
/// services/background_job.py — the server-side counterpart).
protocol JobStatusReporting: Sendable {
    var running: Bool { get }
}

/// Polls a background job's status endpoint until the job reports finished.
///
/// Link check, metadata refresh and batch auto-tagging previously each
/// hand-rolled this loop (sleep → fetch → publish → finish?) with subtle
/// differences and copy-grown bugs. One instance per job type; starting
/// again cancels the previous loop.
@MainActor
final class JobPoller<Status: JobStatusReporting> {
    private var task: Task<Void, Never>?
    private(set) var ticks = 0

    func start(
        interval: TimeInterval,
        fetch: @escaping () async throws -> Status,
        onTick: @escaping (Status) async -> Void,
        onFinished: @escaping (Status) async -> Void,
        onError: @escaping (Error) async -> Void = { _ in }
    ) {
        task?.cancel()
        ticks = 0
        task = Task { [weak self] in
            var consecutiveFailures = 0
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                guard !Task.isCancelled else { return }
                let status: Status
                do {
                    status = try await fetch()
                    consecutiveFailures = 0
                } catch {
                    consecutiveFailures += 1
                    if consecutiveFailures >= 6 {
                        await onError(error)
                        return
                    }
                    continue
                }
                self?.ticks += 1
                await onTick(status)
                if !status.running {
                    await onFinished(status)
                    return
                }
            }
        }
    }

    func stop() {
        task?.cancel()
    }
}
