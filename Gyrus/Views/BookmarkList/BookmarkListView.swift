import SwiftUI

enum ListDisplayMode: String, CaseIterable {
    case grid = "square.grid.2x2"
    case table = "list.bullet"
}

struct BookmarkListView: View {
    @Environment(AppStore.self) private var appStore
    @Environment(BookmarkStore.self) private var bookmarkStore
    @Environment(CollectionStore.self) private var collectionStore
    @Environment(TagStore.self) private var tagStore
    @Environment(UIStateStore.self) private var uiStateStore
    @Binding var showAddBookmark: Bool
    @AppStorage("defaultViewMode") private var defaultViewModeRaw = ListDisplayMode.grid.rawValue
    private var displayMode: ListDisplayMode {
        ListDisplayMode(rawValue: defaultViewModeRaw) ?? .grid
    }
    private var displayModeBinding: Binding<ListDisplayMode> {
        Binding(
            get: { displayMode },
            set: { defaultViewModeRaw = $0.rawValue }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            HStack(spacing: 12) {
                Picker("View Mode", selection: displayModeBinding) {
                    ForEach(ListDisplayMode.allCases, id: \.self) { mode in
                        Image(systemName: mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 80)

                SearchField(
                    text: Binding(
                        get: { bookmarkStore.searchQuery },
                        set: { appStore.scheduleSearch($0) }
                    ),
                    semanticAvailable: AppSettings.shared.aiBrainConfig.aiEnabled && bookmarkStore.semanticSearchAvailable,
                    semanticEnabled: Binding(
                        get: { bookmarkStore.semanticSearchEnabled },
                        set: { bookmarkStore.semanticSearchEnabled = $0 }
                    ),
                    onToggleSemantic: {
                        if !bookmarkStore.searchQuery.isEmpty {
                            Task { await appStore.loadBookmarks() }
                        }
                    }
                )
                .frame(maxWidth: 360)

                Spacer()

                Button {
                    Task { await appStore.selectAllInCurrentView() }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "checklist")
                            .frame(width: 16, height: 16)
                        if !bookmarkStore.selectedIds.isEmpty {
                            Text("\(bookmarkStore.selectedIds.count)")
                                .font(.caption.monospacedDigit())
                        }
                    }
                }
                .buttonStyle(.bordered)
                .disabled(bookmarkStore.bookmarks.isEmpty)
                .help("Select all (⌘A)")

                Menu {
                    Section("Sort by Name") {
                        sortButton("Name (A-Z)", by: "title", order: "asc")
                        sortButton("Name (Z-A)", by: "title", order: "desc")
                    }
                    Section("Sort by Date") {
                        sortButton("Newest first", by: "created_at", order: "desc")
                        sortButton("Oldest first", by: "created_at", order: "asc")
                    }
                    Section("Sort by Tag") {
                        sortButton("Tag (A-Z)", by: "tag", order: "asc")
                        sortButton("Tag (Z-A)", by: "tag", order: "desc")
                    }
                    Section("Sort by Site") {
                        sortButton("Group by favicon", by: "favicon", order: "asc")
                    }
                } label: {
                    Label("Sort", systemImage: "arrow.up.arrow.down")
                }
                .frame(width: 100)

                if collectionStore.showTrash {
                    Button(role: .destructive) {
                        Task { await appStore.emptyTrash() }
                    } label: {
                        Label("Empty Trash", systemImage: "trash.slash")
                    }
                    .buttonStyle(.bordered)
                    .tint(.red)
                    .disabled(bookmarkStore.bookmarks.isEmpty)
                    .help("Permanently delete everything in the Trash")
                }

                Button {
                    showAddBookmark = true
                } label: {
                    Image(systemName: "plus")
                        .frame(width: 16, height: 16)
                }
                .buttonStyle(.bordered)
                .help("Add bookmark (⌘N)")

                SettingsLink {
                    Image(systemName: "gearshape")
                        .frame(width: 16, height: 16)
                }
                .buttonStyle(.bordered)
                .help("Settings (⌘,)")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.bar)

            Divider()

            // List Content
            Group {
                if bookmarkStore.bookmarks.isEmpty && !uiStateStore.isLoading {
                    EmptyStateView()
                } else {
                    content
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if !bookmarkStore.selectedIds.isEmpty {
                SelectionStatusBar()
            }
        }
        .navigationTitle(navigationTitle)
    }

    @ViewBuilder
    private var content: some View {
        ZStack {
            if displayMode == .grid {
                BookmarkGridView()
            } else {
                BookmarkTableView()
            }

            if uiStateStore.isLoading {
                ZStack {
                    Color(.windowBackgroundColor).opacity(0.4)
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("Loading bookmarks…")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func sortButton(_ label: String, by: String, order: String) -> some View {
        Button {
            Task { await appStore.setSort(by: by, order: order) }
        } label: {
            if bookmarkStore.sortBy == by && bookmarkStore.sortOrder == order {
                Label(label, systemImage: "checkmark")
            } else {
                Text(label)
            }
        }
    }

    private var navigationTitle: String {
        let s = AppSettings.shared
        if !bookmarkStore.searchQuery.isEmpty {
            return s.localized("Search: \"\(bookmarkStore.searchQuery)\"")
        }
        if collectionStore.showTrash { return s.localized("Trash") }
        if collectionStore.showUnreadOnly { return s.localized("Unread") }
        if collectionStore.showDeadOnly { return s.localized("Dead Links") }
        if let tag = tagStore.selectedTagName {
            return "#\(tag)"
        }
        return collectionStore.flatCollections.first(where: { $0.id == collectionStore.selectedCollectionId })?.name ?? s.localized("All Bookmarks")
    }
}

/// A rounded search field for the list toolbar. Searches everything —
/// titles, URLs, descriptions, notes and tags — via the backend.
struct SearchField: View {
    @Binding var text: String
    /// When available, a ✨ toggle inside the field switches between keyword and
    /// meaning-based (semantic) search — far clearer than a separate cryptic
    /// toolbar button, and it puts the control where searching happens.
    var semanticAvailable: Bool = false
    @Binding var semanticEnabled: Bool
    var onToggleSemantic: () -> Void = {}

    @FocusState private var focused: Bool

    private var isSemantic: Bool { semanticAvailable && semanticEnabled }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .font(.callout)

            TextField(isSemantic ? "Search by meaning…" : "Search bookmarks & tags…", text: $text)
                .textFieldStyle(.plain)
                .focused($focused)
                .onSubmit { focused = false }

            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Clear search")
            }

            if semanticAvailable {
                Button {
                    semanticEnabled.toggle()
                    onToggleSemantic()
                } label: {
                    Image(systemName: "sparkles")
                        .font(.callout)
                        .foregroundStyle(isSemantic ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
                        .padding(3)
                        .background(isSemantic ? Color.accentColor.opacity(0.15) : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 5))
                }
                .buttonStyle(.plain)
                .help(isSemantic
                      ? "Meaning-based search is ON — finds by concept, not just words. Click for keyword search."
                      : "Click to search by meaning (semantic), not just keywords.")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(Color(.textBackgroundColor).opacity(0.6))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .strokeBorder((focused || isSemantic) ? Color.accentColor.opacity(0.6) : Color.secondary.opacity(0.25),
                              lineWidth: 1)
        )
    }
}

struct SelectionStatusBar: View {
    @Environment(AppStore.self) private var appStore
    @Environment(BookmarkStore.self) private var bookmarkStore
    @Environment(CollectionStore.self) private var collectionStore
    @Environment(UIStateStore.self) private var uiStateStore

    var body: some View {
        @Bindable var bookmarkStore = bookmarkStore
        let count = bookmarkStore.selectedIds.count
        HStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Color.accentColor)
            Text(count == 1 ? "1 bookmark selected" : "\(count) bookmarks selected")
                .font(.callout.weight(.medium))

            Spacer()

            // Bulk AI tag generation — visible next to the other bulk actions so
            // it's discoverable (not just buried in the right-click menu).
            if let status = uiStateStore.batchAutoTagStatus, status.running {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Tagging \(status.processed)/\(status.total)…")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else if !collectionStore.showTrash && AppSettings.shared.aiBrainConfig.aiEnabled {
                // Bulk AI tagging — shown only when AI is enabled (the master
                // switch), like every other AI affordance.
                Button {
                    let ids = Array(bookmarkStore.selectedIds)
                    Task { await appStore.startBatchAutoTag(ids: ids) }
                } label: {
                    Label("Generate Tags", systemImage: "wand.and.stars")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(.purple)
                .help("Auto-tag the selected bookmarks with AI")
            }

            if collectionStore.showTrash {
                Button {
                    let ids = bookmarkStore.selectedIds
                    Task { await appStore.restoreFromTrash(ids: ids) }
                } label: {
                    Label("Restore", systemImage: "arrow.uturn.backward")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button(role: .destructive) {
                    let ids = bookmarkStore.selectedIds
                    Task { await appStore.purgeFromTrash(ids: ids) }
                } label: {
                    Label("Delete Permanently", systemImage: "trash.slash")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(.red)
            } else {
                Button {
                    appStore.requestOpenInBrowser(ids: bookmarkStore.selectedIds)
                } label: {
                    Label("Open", systemImage: "safari")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button(role: .destructive) {
                    appStore.requestDeleteSelected()
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(.red)
            }

            Button {
                bookmarkStore.selectedIds.removeAll()
                bookmarkStore.selectedBookmark = nil
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Deselect all")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
        .overlay(Divider(), alignment: .top)
    }
}

private enum EmptyContext {
    case search(String), collection, tag(String), deadLinks, unread, trash, all

    var icon: String {
        switch self {
        case .search:    return "magnifyingglass"
        case .collection: return "folder"
        case .tag:       return "tag"
        case .deadLinks: return "checkmark.shield"
        case .unread:    return "envelope.open"
        case .trash:     return "trash"
        case .all:       return "bookmark"
        }
    }

    var title: LocalizedStringKey {
        switch self {
        case .search:         return "No results"
        case .collection:     return "Empty folder"
        case .tag(let name):  return "No bookmarks tagged \"\(name)\""
        case .deadLinks:      return "No dead links"
        case .unread:         return "All caught up"
        case .trash:          return "Trash is empty"
        case .all:            return "No bookmarks yet"
        }
    }

    func subtitle(totalCount: Int) -> LocalizedStringKey {
        switch self {
        case .search(let q):  return "No bookmark matches \"\(q)\""
        case .collection:     return "Drag bookmarks here or add new ones"
        case .tag(let name):  return "Right-click a bookmark to assign the \"\(name)\" tag"
        case .deadLinks:      return totalCount > 0 ? "All \(totalCount) links are reachable" : "Run a link check to find dead links"
        case .unread:         return "You've read everything. Nice."
        case .trash:          return "Deleted bookmarks appear here for 30 days before they're removed for good"
        case .all:            return "Add your first bookmark with ⌘N"
        }
    }
}

struct EmptyStateView: View {
    @Environment(BookmarkStore.self) private var bookmarkStore
    @Environment(CollectionStore.self) private var collectionStore
    @Environment(TagStore.self) private var tagStore

    private var context: EmptyContext {
        if !bookmarkStore.searchQuery.isEmpty  { return .search(bookmarkStore.searchQuery) }
        if collectionStore.showTrash             { return .trash }
        if collectionStore.showUnreadOnly        { return .unread }
        if collectionStore.showDeadOnly          { return .deadLinks }
        if let tag = tagStore.selectedTagName { return .tag(tag) }
        if collectionStore.selectedCollectionId != nil { return .collection }
        return .all
    }

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: context.icon)
                .font(.system(size: 40))
                .foregroundStyle(.quaternary)
            Text(context.title)
                .font(.headline)
                .foregroundStyle(.secondary)
            Text(context.subtitle(totalCount: bookmarkStore.totalBookmarkCount))
                .font(.callout)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
