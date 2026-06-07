import SwiftUI

struct CommandPaletteView: View {
    @Binding var isPresented: Bool
    @Environment(BookmarkStore.self) private var bookmarkStore
    @State private var query = ""
    @State private var results: [Bookmark] = []
    @State private var searchTask: Task<Void, Never>?

    var body: some View {
        @Bindable var bookmarkStore = bookmarkStore

        ZStack {
            Color.black.opacity(0.35)
                .ignoresSafeArea()
                .onTapGesture { isPresented = false }

            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Search bookmarks…", text: $query)
                        .textFieldStyle(.plain)
                        .font(.title3)
                        .onSubmit { openFirst() }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)

                if !results.isEmpty {
                    Divider()
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(results) { bm in
                                CommandResultRow(bookmark: bm) {
                                    bookmarkStore.selectedBookmark = bm
                                    isPresented = false
                                }
                            }
                        }
                    }
                    .frame(maxHeight: 360)
                }
            }
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            .shadow(color: .black.opacity(0.3), radius: 30, y: 10)
            .frame(width: 560)
            .padding(.top, 80)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .onChange(of: query) {
            scheduleSearch(query)
        }
        .onExitCommand { isPresented = false }
        .background(
            Button("") { isPresented = false }
                .keyboardShortcut(.escape, modifiers: [])
                .opacity(0)
        )
    }

    private func scheduleSearch(_ q: String) {
        searchTask?.cancel()
        guard !q.isEmpty else { results = []; return }
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard !Task.isCancelled else { return }
            results = (try? await APIClient.shared.search(query: q, limit: 20)) ?? []
        }
    }

    private func openFirst() {
        guard let first = results.first else { return }
        bookmarkStore.selectedBookmark = first
        isPresented = false
    }
}

struct CommandResultRow: View {
    let bookmark: Bookmark
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                FaviconView(faviconPath: bookmark.faviconPath, bookmarkURL: bookmark.url)
                VStack(alignment: .leading, spacing: 2) {
                    Text(bookmark.title)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                    Text(bookmark.url)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Image(systemName: "return")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .opacity(isHovered ? 1 : 0)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(isHovered ? Color(.selectedControlColor).opacity(0.5) : .clear)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}
