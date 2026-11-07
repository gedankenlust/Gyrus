import SwiftUI

/// Top-level tabs of the bookmark detail. Raw values are the persisted
/// "Open bookmarks on" preference (see `AppSettings.canonicalPreviewTab`),
/// so they must not change; user-visible text comes from `title`.
enum PreviewTab: String, CaseIterable, Identifiable {
    case page = "Page"
    case design = "Design"
    case brain = "AI Brain"
    case notes = "Notes"
    var id: String { rawValue }

    /// Literal keys (not `LocalizedStringKey(rawValue)`) so the string
    /// catalog extractor sees them.
    var title: LocalizedStringKey {
        switch self {
        case .page: "Page"
        case .design: "Design"
        case .brain: "AI Brain"
        case .notes: "Notes"
        }
    }

    var icon: String {
        switch self {
        case .page: "doc.text"
        case .design: "paintpalette"
        case .brain: "brain"
        case .notes: "note.text"
        }
    }

    static func fromPreference(_ value: String) -> PreviewTab? {
        PreviewTab(rawValue: AppSettings.canonicalPreviewTab(value))
    }
}

/// How the Page tab shows the bookmark: metadata, extracted text, or the live
/// site. Chosen with one pop-up in the header rather than a second tab row.
enum PreviewPageMode: String, CaseIterable, Identifiable {
    case overview = "Overview"
    case reader = "Reader"
    case live = "Live"

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .overview: "Overview"
        case .reader: "Reader"
        case .live: "Live"
        }
    }

    var icon: String {
        switch self {
        case .overview: "info.circle"
        case .reader: "book.pages"
        case .live: "globe"
        }
    }

    static func fromPreference(_ value: String) -> PreviewPageMode {
        switch value {
        case "Reader": .reader
        case "Web": .live
        default: .overview
        }
    }
}

// MARK: - Detail

/// The selected bookmark's detail: one compact header bar, then the active
/// tab. Owns the state that must survive tab switches (the web view's
/// controller and the Reader text) so flipping tabs does not refetch.
struct BookmarkDetailView: View {
    let bookmark: Bookmark
    @Environment(BookmarkStore.self) private var bookmarkStore

    @State private var controller = WebController()
    @State private var reader = ReaderModel()
    @State private var selectedTab: PreviewTab = PreviewTab.fromPreference(AppSettings.shared.defaultPreviewTab) ?? .page
    @State private var pageMode = PreviewPageMode.fromPreference(AppSettings.shared.defaultPreviewTab)
    @State private var isEditing = false
    @State private var isLoadingDetails = false

    private var availableTabs: [PreviewTab] {
        PreviewTab.allCases.filter { tab in
            if tab == .brain { return AppSettings.shared.aiBrainConfig.aiEnabled }
            return true
        }
    }

    /// The user's preferred starting tab, falling back to Page if that tab
    /// isn't available (e.g. AI Brain while the brain is disabled).
    private var preferredTab: PreviewTab {
        let pref = PreviewTab.fromPreference(AppSettings.shared.defaultPreviewTab) ?? .page
        return availableTabs.contains(pref) ? pref : .page
    }

    var body: some View {
        VStack(spacing: 0) {
            DetailHeaderBar(
                bookmark: bookmark,
                tabs: availableTabs,
                selectedTab: $selectedTab,
                pageMode: $pageMode,
                controller: controller,
                reader: reader,
                isLoadingDetails: isLoadingDetails,
                onEdit: { isEditing = true }
            )
            Divider()

            tabContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        // A sheet instead of swapping the panel content: the user keeps
        // seeing what they are editing, and Cancel/Save sit where macOS
        // puts them.
        .sheet(isPresented: $isEditing) {
            BookmarkEditSheet(bookmark: bookmark)
        }
        .onAppear {
            selectedTab = preferredTab
            pageMode = PreviewPageMode.fromPreference(AppSettings.shared.defaultPreviewTab)
        }
        .onChange(of: bookmark.id) {
            selectedTab = preferredTab
            pageMode = PreviewPageMode.fromPreference(AppSettings.shared.defaultPreviewTab)
            isEditing = false
            reader.reset()
            // The previous site's failure must not flash over the next one.
            controller.loadError = nil
        }
        .task(id: bookmark.id) {
            isLoadingDetails = true
            defer { isLoadingDetails = false }
            do {
                try await bookmarkStore.loadDetails(id: bookmark.id)
                if let current = bookmarkStore.selectedBookmark,
                   current.id == bookmark.id {
                    try await bookmarkStore.fetchMeta(current)
                }
            } catch {
                AppStore.shared.surfaceError(error)
            }
        }
    }

    @ViewBuilder
    private var tabContent: some View {
        switch selectedTab {
        case .page:
            switch pageMode {
            case .overview: OverviewTab(bookmark: bookmark)
            case .reader: ReaderTab(bookmark: bookmark, reader: reader)
            case .live: LiveWebTab(bookmark: bookmark, controller: controller)
            }
        case .design:
            // One identity per bookmark: switching bookmarks must not
            // keep the previous site's design (or its capture job)
            // on screen when loading the new one fails.
            VisualSnapshotTabView(bookmark: bookmark).id(bookmark.id)
        case .brain: AIBrainTabView(bookmark: bookmark)
        case .notes: NotesTab(bookmark: bookmark)
        }
    }
}
