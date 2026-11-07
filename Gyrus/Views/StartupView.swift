import SwiftUI
import AppKit

struct StartupView: View {
    @Environment(BackendLauncher.self) private var launcher

    var body: some View {
        VStack(spacing: 20) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 80, height: 80)
                .accessibilityHidden(true)

            Text("Gyrus")
                .font(.largeTitle.bold())

            if let error = launcher.error {
                errorView(error)
            } else if launcher.isBootstrapping {
                progressView(Text(launcher.bootstrapStatus))
            } else {
                progressView(Text("Starting backend…"))
            }
        }
        .padding(32)
        // Sizes to its content (a long error must not be clipped), at least
        // as wide as the original splash.
        .frame(minWidth: 420, maxWidth: .infinity, minHeight: 300, maxHeight: .infinity)
        .background(.background)
    }

    private func progressView(_ status: Text) -> some View {
        VStack(spacing: 8) {
            ProgressView()
            status
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 14) {
            Label {
                Text("Gyrus couldn’t start")
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            }
            .font(.headline)

            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 440)

            HStack(spacing: 8) {
                Button("Quit Gyrus") { NSApp.terminate(nil) }
                Button("Show Log") { revealLog() }
                    .help("Show the backend log in Finder")
                Button("Try Again") {
                    Task { await launcher.start() }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
            .padding(.top, 4)
        }
    }

    /// Select the backend log in Finder without opening it. Same location
    /// BackendLauncher writes to: ~/Library/Application Support/Gyrus.
    /// Falls back to the bootstrap log (first-run setup failures), then to the
    /// folder itself if neither log exists yet.
    private func revealLog() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dataDir = appSupport.appendingPathComponent("Gyrus")
        let candidates = [
            dataDir.appendingPathComponent("backend.log"),
            dataDir.appendingPathComponent("backend-bootstrap.log"),
        ]
        if let log = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) {
            NSWorkspace.shared.activateFileViewerSelecting([log])
        } else if FileManager.default.fileExists(atPath: dataDir.path) {
            NSWorkspace.shared.activateFileViewerSelecting([dataDir])
        } else {
            NSSound.beep()
        }
    }
}
