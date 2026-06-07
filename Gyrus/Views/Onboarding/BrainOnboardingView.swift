import SwiftUI
import AppKit

/// One-time prompt shown on first launch: lets the user opt into the AI Brain
/// and pick where its Markdown files live. Skipping leaves the brain disabled.
struct BrainOnboardingView: View {
    @Binding var isPresented: Bool

    @State private var chosenPath: String = BrainOnboardingView.defaultLocation()

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "brain.head.profile")
                .font(.system(size: 44))
                .foregroundStyle(.pink.gradient)
                .padding(.top, 4)

            Text("AI Brain")
                .font(.title2.bold())

            Text("Gyrus can keep a Markdown note for each bookmark and let you chat about a page with a local AI (Ollama). It's optional — you can turn it on or off anytime in Settings.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            // Storage location
            VStack(alignment: .leading, spacing: 6) {
                Text("Storage location")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                HStack(spacing: 10) {
                    Image(systemName: "folder.fill")
                        .foregroundStyle(Color.accentColor)
                    Text(chosenPath)
                        .font(.callout)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(chosenPath)
                    Spacer()
                    Button("Change…") { chooseLocation() }
                }
                .padding(10)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
            }

            Label("Everything stays on your Mac. Nothing is uploaded.", systemImage: "lock.fill")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                Button("Not now") { skip() }
                    .keyboardShortcut(.cancelAction)

                Button("Enable AI Brain") { enable() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
            .padding(.top, 4)
        }
        .padding(28)
        .frame(width: 460)
    }

    // MARK: - Actions

    private func enable() {
        var config = AppSettings.shared.aiBrainConfig
        config.isEnabled = true
        config.rootDirectoryPath = chosenPath
        // The setter persists the config and pushes it to the backend.
        AppSettings.shared.aiBrainConfig = config
        finish()
    }

    private func skip() {
        // Leave the brain disabled; just don't ask again.
        finish()
    }

    private func finish() {
        AppSettings.shared.didCompleteBrainOnboarding = true
        isPresented = false
    }

    private func chooseLocation() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url {
            chosenPath = AppSettings.brainRoot(forChosenDirectory: url)
        }
    }

    /// Default suggestion: a visible, dedicated folder in Documents.
    private static func defaultLocation() -> String {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        return docs.appendingPathComponent("Gyrus Brain").path
    }
}
