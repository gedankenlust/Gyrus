import Foundation
import Observation

/// One ordered writer for the process-local backend configuration.
@MainActor @Observable
final class AIConfigSync {
    static let shared = AIConfigSync()
    private(set) var confirmed: AIBrainConfig?
    private(set) var error: String?
    private(set) var isSyncing = false
    private var desired: AIBrainConfig?
    private var revision = 0
    private var worker: Task<Void, Never>?
    private let send: (AIBrainConfig) async throws -> Void

    init(send: @escaping (AIBrainConfig) async throws -> Void = { try await APIClient.shared.updateAIBrainConfig($0) }) {
        self.send = send
    }

    func submit(_ config: AIBrainConfig, force: Bool = false) {
        guard force || config != desired || error != nil || confirmed != config else { return }
        desired = config
        revision += 1
        guard worker == nil else { return }
        isSyncing = true
        worker = Task { [weak self] in
            guard let self else { return }
            while let next = self.desired {
                let revision = self.revision
                do {
                    try await self.send(next)
                    self.confirmed = next
                    self.error = nil
                } catch {
                    self.error = String(localized: "AI settings have not reached the backend.") + " " + error.localizedDescription
                }
                if revision == self.revision { break }
            }
            self.isSyncing = false
            self.worker = nil
        }
    }

    @discardableResult
    func synchronize(_ config: AIBrainConfig, force: Bool = false) async -> Bool {
        submit(config, force: force)
        await worker?.value
        return confirmed == desired && error == nil
    }
}
