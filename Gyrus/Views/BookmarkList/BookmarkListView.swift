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
    @Binding var showInspector: Bool
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

    private var semanticSearchAvailable: Bool {
        AppSettings.shared.aiBrainConfig.aiEnabled && bookmarkStore.semanticSearchAvailable
    }

    var body: some View {
        VStack(spacing: 0) {
            if bookmarkStore.usingKeywordFallback && !bookmarkStore.searchQuery.isEmpty {
                Label("No results by meaning. Showing keyword matches instead.",
                      systemImage: "text.magnifyingglass")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
                    .background(.bar)
                Divider()
            }

            Group {
                if appStore.loadError != nil && bookmarkStore.bookmarks.isEmpty {
                    LibraryLoadErrorView()
                } else if bookmarkStore.bookmarks.isEmpty && !uiStateStore.isLoading {
                    EmptyStateView(showAddBookmark: $showAddBookmark)
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
        .toolbar { toolbarContent }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        // Only while refreshing: on macOS 26 every toolbar item sits on its own
        // glass capsule, so a spinner kept invisible to hold its space showed
        // as an empty capsule next to the title the rest of the time.
        if uiStateStore.isRefreshingBookmarks {
            ToolbarItem(placement: .navigation) {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Refreshing bookmarks")
            }
        }

        ToolbarItemGroup(placement: .primaryAction) {
            Picker("View", selection: displayModeBinding) {
                Label("Grid", systemImage: ListDisplayMode.grid.rawValue).tag(ListDisplayMode.grid)
                Label("List", systemImage: ListDisplayMode.table.rawValue).tag(ListDisplayMode.table)
            }
            .pickerStyle(.segmented)
            .help("Show bookmarks as a grid or a list")

            Menu {
                sortSection
            } label: {
                Label("Sort", systemImage: "arrow.up.arrow.down")
            }
            .help("Sort bookmarks")

            if semanticSearchAvailable {
                Toggle(isOn: Binding(
                    get: { bookmarkStore.semanticSearchEnabled },
                    set: { enabled in
                        bookmarkStore.semanticSearchEnabled = enabled
                        if !bookmarkStore.searchQuery.isEmpty {
                            Task { await appStore.loadBookmarks() }
                        }
                    }
                )) {
                    Label("Search by Meaning", systemImage: "sparkles")
                }
                .help(bookmarkStore.semanticSearchEnabled
                      ? "Search by meaning is on: it finds related concepts, not just matching words."
                      : "Search by meaning instead of matching words.")
            }

            if collectionStore.showTrash {
                Button(role: .destructive) {
                    appStore.trash.requestEmptyTrash()
                } label: {
                    Label("Empty Trash", systemImage: "trash.slash")
                }
                .disabled(bookmarkStore.bookmarks.isEmpty)
                .help("Permanently delete everything in the Trash")
            }

            Button {
                showAddBookmark = true
            } label: {
                Label("Add Bookmark", systemImage: "plus")
            }
            .help("Add bookmark (⌘N)")

            Button {
                showInspector.toggle()
            } label: {
                Label(showInspector ? "Hide Inspector" : "Show Inspector", systemImage: "sidebar.trailing")
            }
            .help("Show or hide the preview (⌥⌘I)")
        }
    }

    @ViewBuilder
    private var sortSection: some View {
        Section("Name") {
            sortButton("Name (A–Z)", by: "title", order: "asc")
            sortButton("Name (Z–A)", by: "title", order: "desc")
        }
        Section("Date Added") {
            sortButton("Newest First", by: "created_at", order: "desc")
            sortButton("Oldest First", by: "created_at", order: "asc")
        }
        Section("Tag") {
            sortButton("Tag (A–Z)", by: "tag", order: "asc")
            sortButton("Tag (Z–A)", by: "tag", order: "desc")
        }
        Section("Site") {
            sortButton("Group by Site", by: "favicon", order: "asc")
        }
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

    /// Takes a catalog key, not a String, so the sort labels are translated.
    private func sortButton(_ label: LocalizedStringKey, by: String, order: String) -> some View {
        Toggle(isOn: Binding(
            get: { bookmarkStore.sortBy == by && bookmarkStore.sortOrder == order },
            set: { _ in Task { await appStore.setSort(by: by, order: order) } }
        )) {
            Text(label)
        }
    }

    private var navigationTitle: String {
        let s = AppSettings.shared
        if !bookmarkStore.searchQuery.isEmpty {
            return s.localized("Search: “\(bookmarkStore.searchQuery)”")
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

/// The library could not be loaded at all. "No bookmarks yet" here would
/// suggest the data is gone.
struct LibraryLoadErrorView: View {
    @Environment(AppStore.self) private var appStore

    var body: some View {
        ContentUnavailableView {
            Label("Library Unavailable", systemImage: "exclamationmark.triangle")
        } description: {
            Text(appStore.loadError ?? "")
                .textSelection(.enabled)
        } actions: {
            Button("Try Again") { Task { await appStore.loadAll() } }
                .buttonStyle(.borderedProminent)
        }
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

            // A narrow list column cannot fit the sentence and the titled
            // buttons; hyphenating the sentence over four lines and cutting
            // the buttons to "…" helped nobody. Fall back to the bare count
            // and icon buttons, whose names stay in the tooltips.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    Text(count == 1 ? "1 bookmark selected" : "\(count) bookmarks selected")
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                    Spacer(minLength: 12)
                    actions
                }
                HStack(spacing: 8) {
                    Text(verbatim: "\(count)")
                        .font(.callout.weight(.medium).monospacedDigit())
                        .lineLimit(1)
                        .accessibilityLabel(count == 1 ? "1 bookmark selected" : "\(count) bookmarks selected")
                    Spacer(minLength: 8)
                    actions
                        .labelStyle(.iconOnly)
                }
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
                .accessibilityLabel("Deselect all")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
        .overlay(Divider(), alignment: .top)
    }

    /// The selection's actions. Both bar layouts show the same controls, so
    /// the compact one only changes how their labels are drawn.
    @ViewBuilder
    private var actions: some View {
        // Keep one clear entry point: organize automatically or choose tags manually.
        if let status = appStore.jobs.batchAutoTagStatus, status.running {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(progressLabel(status))
                    .font(.caption).foregroundStyle(.secondary)
                Button {
                    Task { await appStore.jobs.cancelBatchAutoTag() }
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(.red)
                .help("Stop analysis — no tags are changed before review")
            }
        } else if !collectionStore.showTrash {
            if bookmarkStore.isFilteringSelection {
                ProgressView().controlSize(.small)
                    .accessibilityLabel("Checking tags…")
            }
            Menu {
                Button {
                    Task { await appStore.deselectTaggedBookmarks() }
                } label: {
                    Label("Deselect tagged bookmarks", systemImage: "minus.circle")
                }

                Divider()

                Button {
                    let ids = Array(bookmarkStore.selectedIds)
                    Task { await appStore.jobs.startTaxonomyReview(ids: ids) }
                } label: {
                    Label("Organize with AI", systemImage: "wand.and.stars")
                }
                .disabled(!AppSettings.shared.aiBrainConfig.aiEnabled
                          || bookmarkStore.selectedIds.count < BackgroundJobs.minTaxonomyBookmarks)

                if !AppSettings.shared.aiBrainConfig.aiEnabled {
                    Text("Enable AI in Settings to organize automatically")
                } else if bookmarkStore.selectedIds.count < BackgroundJobs.minTaxonomyBookmarks {
                    Text("Select at least 10 bookmarks for AI organization")
                }

                Divider()

                Button {
                    uiStateStore.tagAssignmentForIds = bookmarkStore.selectedIds
                } label: {
                    Label("Choose Tags Manually…", systemImage: "tag")
                }
            } label: {
                Label("Organize", systemImage: "wand.and.stars")
            }
            .controlSize(.small)
            .tint(.purple)
            .disabled(bookmarkStore.isFilteringSelection)
            .help("Organize the selected bookmarks automatically or choose tags manually")
        }

        if collectionStore.showTrash {
            Button {
                let ids = bookmarkStore.selectedIds
                Task { await appStore.trash.restoreFromTrash(ids: ids) }
            } label: {
                Label("Restore", systemImage: "arrow.uturn.backward")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("Restore")

            Button(role: .destructive) {
                appStore.trash.requestPurge(ids: bookmarkStore.selectedIds)
            } label: {
                Label("Delete Permanently", systemImage: "trash.slash")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("Delete Permanently")
            .tint(.red)
        } else {
            Button {
                appStore.requestOpenInBrowser(ids: bookmarkStore.selectedIds)
            } label: {
                Label("Open", systemImage: "safari")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("Open")

            Button(role: .destructive) {
                appStore.trash.requestDeleteSelected()
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("Delete")
            .tint(.red)
        }
    }

    private func progressLabel(_ status: BatchAutoTagStatus) -> String {
        if status.phase == "cooldown" {
            return AppSettings.shared.localized("Gentle mode · resting for \(status.cooldownRemaining)s…")
        }
        if status.phase == "embedding" {
            return AppSettings.shared.localized("Analyzing meaning: \(status.embedded)/\(status.total)…")
        }
        if status.phase == "clustering" {
            return AppSettings.shared.localized("Grouping \(status.total) related bookmarks…")
        }
        if status.phase == "labeling" {
            let model = status.model ?? "AI"
            return status.generatedTokens > 0
                ? AppSettings.shared.localized("\(model) names groups · \(status.generatedTokens) tokens…")
                : AppSettings.shared.localized("\(model) names the topic groups…")
        }
        if status.phase == "assigning" {
            return status.generatedTokens > 0
                ? AppSettings.shared.localized("Assigning tags: \(status.classified)/\(status.total) · \(status.generatedTokens) tokens…")
                : AppSettings.shared.localized("Assigning tags: \(status.classified)/\(status.total)…")
        }
        if status.phase == "validating" {
            let model = status.model ?? "AI"
            return status.generatedTokens > 0
                ? AppSettings.shared.localized("\(model) checks · \(status.generatedTokens) tokens…")
                : AppSettings.shared.localized("\(model) checks every assignment…")
        }
        if status.phase == "repairing" {
            return status.generatedTokens > 0
                ? AppSettings.shared.localized("Refining suggestions · \(status.generatedTokens) tokens…")
                : AppSettings.shared.localized("Checking and refining suggestions…")
        }
        if status.phase == "organizing" {
            let model = status.model ?? "AI"
            return status.generatedTokens > 0
                ? AppSettings.shared.localized("\(model) generates · \(status.generatedTokens) tokens…")
                : AppSettings.shared.localized("\(model) reads \(status.total) bookmarks…")
        }
        return AppSettings.shared.localized("Analyzing \(status.processed)/\(status.total)…")
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
    @Binding var showAddBookmark: Bool

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
        ContentUnavailableView {
            Label(context.title, systemImage: context.icon)
        } description: {
            Text(context.subtitle(totalCount: bookmarkStore.totalBookmarkCount))
        } actions: {
            switch context {
            case .all:
                Button("Add Bookmark") { showAddBookmark = true }
                    .buttonStyle(.borderedProminent)
                Button("Import Bookmarks…") {
                    NotificationCenter.default.post(name: .showImport, object: nil)
                }
            case .collection:
                Button("Add Bookmark") { showAddBookmark = true }
            default:
                EmptyView()
            }
        }
    }
}
