import SwiftUI

struct AddBookmarkView: View {
    @Binding var isPresented: Bool
    @Environment(AppStore.self) private var appStore
    @Environment(BookmarkStore.self) private var bookmarkStore
    @Environment(CollectionStore.self) private var collectionStore

    @State private var url = ""
    @State private var title = ""
    @State private var selectedCollectionId: String? = nil
    @State private var isSaving = false
    @State private var errorMsg: String? = nil

    var body: some View {
        VStack(spacing: 24) {
            // Header
            VStack(spacing: 6) {
                Image(systemName: "bookmark.fill")
                    .font(.system(size: 36))
                    .foregroundStyle(Color.accentColor)
                Text("Add Bookmark")
                    .font(.title2.bold())
            }

            VStack(alignment: .leading, spacing: 14) {
                // URL
                VStack(alignment: .leading, spacing: 5) {
                    Text("URL").font(.callout.weight(.medium))
                    HStack {
                        TextField("https://example.com", text: $url)
                            .textFieldStyle(.roundedBorder)
                            .onChange(of: url) { autoFillTitle() }
                        Button {
                            if let clip = NSPasteboard.general.string(forType: .string) {
                                url = clip.trimmingCharacters(in: .whitespacesAndNewlines)
                                autoFillTitle()
                            }
                        } label: {
                            Image(systemName: "doc.on.clipboard")
                        }
                        .buttonStyle(.bordered)
                        .help("Paste from clipboard")
                    }
                }

                // Title
                VStack(alignment: .leading, spacing: 5) {
                    Text("Title").font(.callout.weight(.medium))
                    TextField("Automatic from URL", text: $title)
                        .textFieldStyle(.roundedBorder)
                }

                // Collection
                VStack(alignment: .leading, spacing: 5) {
                    Text("Folder").font(.callout.weight(.medium))
                    Picker("Folder", selection: $selectedCollectionId) {
                        Text("No folder").tag(Optional<String>.none)
                        ForEach(collectionStore.flatCollections) { col in
                            Text(col.name).tag(Optional(col.id))
                        }
                    }
                    .labelsHidden()
                }
            }

            if let err = errorMsg {
                Text(err).font(.callout).foregroundStyle(.red).multilineTextAlignment(.center)
            }

            // Actions
            HStack {
                Button("Cancel") { isPresented = false }
                    .buttonStyle(.bordered)
                Spacer()
                Button {
                    Task { await save() }
                } label: {
                    if isSaving {
                        ProgressView().scaleEffect(0.8)
                    } else {
                        Text("Add")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSaving)
            }
        }
        .padding(24)
        .frame(width: 440)
    }

    private func autoFillTitle() {
        guard title.isEmpty, let host = URL(string: url)?.host else { return }
        title = host
    }

    private func save() async {
        let trimmedURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedURL.isEmpty else { return }

        guard let parsed = URL(string: trimmedURL),
              parsed.scheme == "https" || parsed.scheme == "http" else {
            errorMsg = String(localized: "Please enter a valid URL (https://...)")
            return
        }

        isSaving = true
        errorMsg = nil
        defer { isSaving = false }

        do {
            let body = BookmarkCreate(
                title: title.isEmpty ? trimmedURL : title,
                url: trimmedURL,
                description: nil,
                notes: nil,
                collectionId: selectedCollectionId,
                tagIds: [],
                source: "manual"
            )
            let newBookmark = try await APIClient.shared.createBookmark(body)
            // Reload within the current view (folder/tag/search), not all bookmarks.
            await appStore.loadBookmarks()
            
            // Selection sync: show the new bookmark details
            bookmarkStore.selectedIds = [newBookmark.id]
            bookmarkStore.selectedBookmark = newBookmark
            
            isPresented = false
        } catch APIError.serverError(409) {
            errorMsg = String(localized: "This URL is already in your collection.")
        } catch {
            errorMsg = error.localizedDescription
        }
    }
}
