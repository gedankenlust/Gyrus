import SwiftUI
import AppKit

/// Compact "save a bookmark" form shown from the menu bar or the global
/// quick-add hotkey. Pre-fills the URL from the clipboard when it holds a link.
struct QuickAddPanel: View {
    /// Called when the panel should dismiss itself.
    var onClose: () -> Void

    @State private var url: String = ""
    @State private var selectedCollectionId: String? = nil   // nil = Inbox (auto)
    @State private var phase: Phase = .idle

    private enum Phase: Equatable {
        case idle, saving, saved, duplicate, error(String)
    }

    private let collections = AppStore.shared.collectionsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "bookmark.fill")
                    .foregroundStyle(Color.accentColor)
                Text("Quick Add")
                    .font(.headline)
                Spacer()
            }

            TextField("https://…", text: $url)
                .textFieldStyle(.roundedBorder)
                .font(.body)
                .onSubmit(save)

            HStack {
                Text("Folder")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Picker("", selection: $selectedCollectionId) {
                    Text("Inbox").tag(String?.none)
                    Divider()
                    ForEach(collections.flatCollections, id: \.id) { col in
                        Text(col.name).tag(String?.some(col.id))
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 200)
            }

            statusRow

            HStack {
                Button("Cancel", action: onClose)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(action: save) {
                    if phase == .saving {
                        ProgressView().scaleEffect(0.6)
                    } else {
                        Text("Save")
                    }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(!isValidURL || phase == .saving)
            }
        }
        .padding(18)
        .frame(width: 380)
        .onAppear(perform: prefillFromClipboard)
    }

    @ViewBuilder
    private var statusRow: some View {
        switch phase {
        case .saved:
            Label("Saved to bookmarks", systemImage: "checkmark.circle.fill")
                .font(.caption).foregroundStyle(.green)
        case .duplicate:
            Label("Already saved", systemImage: "info.circle.fill")
                .font(.caption).foregroundStyle(.orange)
        case .error(let msg):
            Label(msg, systemImage: "exclamationmark.triangle.fill")
                .font(.caption).foregroundStyle(.red)
        default:
            EmptyView()
        }
    }

    private var isValidURL: Bool {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let u = URL(string: trimmed) else { return false }
        return u.scheme == "http" || u.scheme == "https"
    }

    private func prefillFromClipboard() {
        guard url.isEmpty,
              let clip = NSPasteboard.general.string(forType: .string)?
                  .trimmingCharacters(in: .whitespacesAndNewlines),
              let u = URL(string: clip),
              u.scheme == "http" || u.scheme == "https" else { return }
        url = clip
    }

    private func save() {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isValidURL else { return }
        phase = .saving
        Task {
            do {
                _ = try await APIClient.shared.createBookmark(.init(
                    title: "", url: trimmed, description: nil, notes: nil,
                    collectionId: selectedCollectionId, tagIds: [], source: "menubar"
                ))
                phase = .saved
                // Refresh the main window so the new bookmark shows up.
                await AppStore.shared.loadAll()
                try? await Task.sleep(nanoseconds: 800_000_000)
                onClose()
            } catch APIError.duplicate {
                phase = .duplicate
            } catch {
                phase = .error(error.localizedDescription)
            }
        }
    }
}
