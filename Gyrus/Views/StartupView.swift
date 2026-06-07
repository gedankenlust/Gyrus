import SwiftUI
import AppKit

struct StartupView: View {
    @Environment(BackendLauncher.self) private var launcher

    var body: some View {
        VStack(spacing: 20) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 80, height: 80)

            Text("Gyrus")
                .font(.largeTitle.bold())

            if let error = launcher.error {
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                    Text(error)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)

                    Button("Retry") {
                        Task { await launcher.start() }
                    }
                    .buttonStyle(.borderedProminent)
                }
            } else if launcher.isBootstrapping {
                VStack(spacing: 8) {
                    ProgressView()
                    Text(launcher.bootstrapStatus)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } else {
                VStack(spacing: 8) {
                    ProgressView()
                    Text("Starting backend…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: 400, height: 300)
        .background(.background)
    }
}
