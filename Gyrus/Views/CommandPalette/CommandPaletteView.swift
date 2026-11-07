import SwiftUI

struct CommandPaletteView: View {
    @Binding var isPresented: Bool
    @Environment(BookmarkStore.self) private var bookmarkStore
    @State private var query = ""
    @State private var results: [Bookmark] = []
    /// Row that ↑/↓ move and Return opens.
    @State private var highlightedIndex = 0
    @State private var isSearching = false
    /// True once a search for the current (non-empty) query finished, so an
    /// empty result list means "nothing found" rather than "not searched yet".
    @State private var hasSearched = false
    @State private var searchError: String?
    @State private var searchTask: Task<Void, Never>?
    @FocusState private var isFieldFocused: Bool

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.35)
                .ignoresSafeArea()
                .onTapGesture { close() }
                .accessibilityHidden(true)

            VStack(spacing: 0) {
                searchField
                resultsArea
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
        .onAppear {
            isFieldFocused = true
            // The overlay is inserted mid-update; claim focus again once it
            // is in the window so typing always lands in the field.
            DispatchQueue.main.async { isFieldFocused = true }
        }
        .onDisappear { searchTask?.cancel() }
        .onExitCommand { close() }
        .background(
            Button("") { close() }
                .keyboardShortcut(.escape, modifiers: [])
                .opacity(0)
                .accessibilityHidden(true)
        )
    }

    // MARK: - Field

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField("Search bookmarks…", text: $query)
                .textFieldStyle(.plain)
                .font(.title3)
                .focused($isFieldFocused)
                .onSubmit { openHighlighted() }
                .onKeyPress(.upArrow) {
                    moveHighlight(by: -1)
                    return .handled
                }
                .onKeyPress(.downArrow) {
                    moveHighlight(by: 1)
                    return .handled
                }
                .onKeyPress(.escape) {
                    close()
                    return .handled
                }
            if isSearching {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    // MARK: - Results

    @ViewBuilder
    private var resultsArea: some View {
        if !trimmedQuery.isEmpty {
            if let searchError {
                Divider()
                errorRow(searchError)
            } else if !results.isEmpty {
                Divider()
                resultList
            } else if hasSearched {
                Divider()
                ContentUnavailableView.search(text: trimmedQuery)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
            }
        }
    }

    private var resultList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(results.enumerated()), id: \.element.id) { index, bm in
                        CommandResultRow(bookmark: bm, isHighlighted: index == highlightedIndex) {
                            open(bm)
                        }
                        .id(bm.id)
                        .onHover { hovering in
                            if hovering { highlightedIndex = index }
                        }
                    }
                }
            }
            .frame(maxHeight: 360)
            .onChange(of: highlightedIndex) {
                guard results.indices.contains(highlightedIndex) else { return }
                proxy.scrollTo(results[highlightedIndex].id)
            }
        }
    }

    private func errorRow(_ message: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Search failed")
                    .font(.callout.weight(.medium))
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Spacer()
            Button("Try Again") { scheduleSearch(query, debounce: false) }
                .controlSize(.small)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .accessibilityElement(children: .contain)
    }

    // MARK: - Actions

    private func moveHighlight(by delta: Int) {
        guard !results.isEmpty else { return }
        highlightedIndex = min(max(highlightedIndex + delta, 0), results.count - 1)
    }

    private func openHighlighted() {
        guard results.indices.contains(highlightedIndex) else { return }
        open(results[highlightedIndex])
    }

    /// Reveal the bookmark in the library: select it and show its preview.
    private func open(_ bookmark: Bookmark) {
        bookmarkStore.selectedIds = [bookmark.id]
        bookmarkStore.selectedBookmark = bookmark
        close()
    }

    private func close() {
        searchTask?.cancel()
        isPresented = false
    }

    private func scheduleSearch(_ text: String, debounce: Bool = true) {
        searchTask?.cancel()
        let q = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else {
            results = []
            searchError = nil
            hasSearched = false
            isSearching = false
            highlightedIndex = 0
            return
        }
        searchTask = Task {
            if debounce {
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard !Task.isCancelled else { return }
            }
            isSearching = true
            do {
                let found = try await APIClient.shared.search(query: q, limit: 20)
                guard !Task.isCancelled else { return }
                results = found
                searchError = nil
            } catch {
                // A newer keystroke cancelled this search; its own task
                // reports the outcome.
                guard !Task.isCancelled else { return }
                results = []
                searchError = error.localizedDescription
            }
            highlightedIndex = 0
            hasSearched = true
            isSearching = false
        }
    }
}

struct CommandResultRow: View {
    let bookmark: Bookmark
    let isHighlighted: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                FaviconView(faviconPath: bookmark.faviconPath, bookmarkURL: bookmark.url)
                VStack(alignment: .leading, spacing: 2) {
                    Text(bookmark.displayTitle)
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
                    .foregroundStyle(.secondary)
                    .opacity(isHighlighted ? 1 : 0)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(isHighlighted ? Color(.selectedContentBackgroundColor).opacity(0.25) : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isHighlighted ? .isSelected : [])
    }
}
