import SwiftUI
import Combine

struct ContentView: View {
    @Environment(AppStore.self) private var appStore
    @Environment(BookmarkStore.self) private var bookmarkStore
    @Environment(UIStateStore.self) private var uiStateStore
    
    @Environment(TagStore.self) private var tagStore

    @State private var showImport = false
    @State private var showAddBookmark = false
    @State private var showCommandPalette = false
    @State private var showWelcome = false
    @State private var welcomeAction = ""
    @State private var newTagName = ""
    @State private var newTagError: String?
    @State private var isSavingTag = false
    @State private var newTagColor: Color = .blue
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @AppStorage(InspectorVisibility.storageKey) private var showInspector = true

    private var semanticSearchAvailable: Bool {
        AppSettings.shared.aiBrainConfig.aiEnabled && bookmarkStore.semanticSearchAvailable
    }

    private var confirmTitle: String {
        let n = uiStateStore.pendingBatchOpen?.count ?? 0
        return String(localized: "Open \(n) bookmarks at once?")
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var toastAnimation: Animation {
        reduceMotion ? .easeInOut(duration: 0.15) : .spring(duration: 0.3)
    }

    private func toastTransition(edge: Edge) -> AnyTransition {
        reduceMotion ? .opacity : .move(edge: edge).combined(with: .opacity)
    }

    private var purgeConfirmTitle: String {
        switch appStore.trash.pendingPurge {
        case .all:
            return String(localized: "Empty the Trash?")
        case .ids(let ids):
            return String(localized: "Permanently delete \(ids.count) bookmarks?")
        case nil:
            return ""
        }
    }

    private var deleteConfirmTitle: String {
        let n = appStore.trash.pendingBatchDelete?.count ?? 0
        return String(localized: "Delete \(n) bookmarks?")
    }

    var body: some View {
        let base = librarySplitView
            .disabled(appStore.isReplacingLibrary)
        let sheeted = withSheets(base)
        let confirmed = withDialogs(sheeted)
        return withOverlays(confirmed)
    }

    private var librarySplitView: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 300)
        } detail: {
            BookmarkListView(showAddBookmark: $showAddBookmark, showInspector: $showInspector)
                .frame(minWidth: 320)
                // The preview is an inspector the user can hide (⌥⌘I), so a
                // narrow window keeps a usable list instead of three cramped
                // fixed columns.
                .inspector(isPresented: $showInspector) {
                    PreviewPanelView()
                        .inspectorColumnWidth(min: 340, ideal: 480, max: 960)
                }
        }
        .searchable(
            text: Binding(
                get: { bookmarkStore.searchQuery },
                set: { appStore.scheduleSearch($0) }
            ),
            placement: .toolbar,
            prompt: bookmarkStore.semanticSearchEnabled && semanticSearchAvailable
                ? Text("Search by meaning")
                : Text("Search bookmarks and tags")
        )
    }

    private func withSheets(_ content: some View) -> some View {
        @Bindable var bookmarkStore = bookmarkStore
        @Bindable var uiStateStore = uiStateStore
        return content
        .sheet(isPresented: $showImport) {
            ImportWizardView(isPresented: $showImport)
        }
        .sheet(isPresented: $showAddBookmark) {
            AddBookmarkView(isPresented: $showAddBookmark)
        }
        .sheet(isPresented: $showWelcome, onDismiss: {
            AppSettings.shared.didCompleteBrainOnboarding = true
            if welcomeAction == "import" { showImport = true }
            if welcomeAction == "add" { showAddBookmark = true }
            welcomeAction = ""
        }) {
            VStack(alignment: .leading, spacing: 18) {
                Text("Welcome to Gyrus").font(.title2.bold())
                Text("Keep your bookmarks, folders and notes together on this Mac.")
                Button("Import existing bookmarks…") { welcomeAction = "import"; showWelcome = false }
                    .buttonStyle(.borderedProminent)
                Button("Add your first bookmark…") { welcomeAction = "add"; showWelcome = false }
                Text("You can enable optional local AI later in Settings.").font(.caption).foregroundStyle(.secondary)
                HStack { Spacer(); Button("Start exploring") { showWelcome = false } }
            }.padding(28).frame(width: 430)
        }
        .sheet(isPresented: Binding(
            get: { uiStateStore.newTagForIds != nil },
            set: { if !$0 { uiStateStore.newTagForIds = nil } }
        )) {
            TagEditorSheet(
                title: "New Tag",
                name: $newTagName,
                color: $newTagColor,
                onSave: {
                    let name = newTagName.trimmingCharacters(in: .whitespacesAndNewlines)
                    let color = newTagColor.toHex()
                    guard !isSavingTag, let ids = uiStateStore.newTagForIds, !name.isEmpty else { return }
                    isSavingTag = true
                    newTagError = nil
                    Task {
                        defer { isSavingTag = false }
                        do {
                            let updated = try await tagStore.createTagAndAssign(name: name, color: color,
                                toBookmarkIds: ids, in: bookmarkStore.bookmarks)
                            bookmarkStore.applyUpdated(updated)
                            uiStateStore.newTagForIds = nil
                            newTagName = ""
                        } catch { newTagError = error.localizedDescription }
                    }
                },
                onCancel: { uiStateStore.newTagForIds = nil; newTagName = ""; newTagError = nil },
                errorMessage: newTagError,
                isSaving: isSavingTag
            )
        }
        .sheet(isPresented: Binding(
            get: { uiStateStore.tagAssignmentForIds != nil },
            set: { if !$0 { uiStateStore.tagAssignmentForIds = nil } }
        )) {
            if let ids = uiStateStore.tagAssignmentForIds {
                BulkTagAssignmentSheet(
                    bookmarkIds: ids,
                    bookmarks: bookmarkStore.bookmarks,
                    tags: tagStore.tags,
                    onCancel: { uiStateStore.tagAssignmentForIds = nil },
                    onCreateTag: { suggestedName in
                        newTagName = suggestedName
                        uiStateStore.tagAssignmentForIds = nil
                        uiStateStore.newTagForIds = ids
                    },
                    onApply: { addIds, removeIds in
                        Task {
                            let applied = await appStore.applyBulkTagChanges(
                                to: ids,
                                addTagIds: addIds,
                                removeTagIds: removeIds
                            )
                            if applied { uiStateStore.tagAssignmentForIds = nil }
                        }
                    }
                )
            }
        }
        .sheet(item: Binding(
            get: { appStore.jobs.batchTagReview },
            set: { appStore.jobs.batchTagReview = $0 }
        )) { payload in
            TagReviewSheet(payload: payload) {
                appStore.jobs.batchTagReview = nil
                Task { await appStore.discardTaxonomyDraft(payload.draft) }
            } onApply: { edits in
                appStore.jobs.batchTagReview = nil
                Task { await appStore.applyTaxonomyDraft(payload.draft, edits: edits) }
            }
        }
        .onAppear {
            // First launch starts with the core bookmark workflow.
            if !AppSettings.shared.didCompleteBrainOnboarding {
                showWelcome = true
            }
        }
    }

    private func withDialogs(_ content: some View) -> some View {
        content
        .confirmationDialog(
            confirmTitle,
            isPresented: Binding(
                get: { uiStateStore.pendingBatchOpen != nil },
                set: { if !$0 { appStore.cancelPendingOpen() } }
            ),
            titleVisibility: .visible
        ) {
            Button("Open All", role: .none) {
                appStore.confirmPendingOpen()
            }
            Button("Cancel", role: .cancel) {
                appStore.cancelPendingOpen()
            }
        } message: {
            Text("This opens \(uiStateStore.pendingBatchOpen?.count ?? 0) tabs in your browser. That can put it under heavy load.")
        }
        .confirmationDialog(
            deleteConfirmTitle,
            isPresented: Binding(
                get: { appStore.trash.pendingBatchDelete != nil },
                set: { if !$0 { appStore.trash.cancelPendingDelete() } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete All", role: .destructive) {
                appStore.trash.confirmPendingDelete()
            }
            Button("Cancel", role: .cancel) {
                appStore.trash.cancelPendingDelete()
            }
        } message: {
            Text("This moves \(appStore.trash.pendingBatchDelete?.count ?? 0) bookmarks to Trash for 30 days. You can undo for 5 seconds.")
        }
        .confirmationDialog(
            purgeConfirmTitle,
            isPresented: Binding(
                get: { appStore.trash.pendingPurge != nil },
                set: { if !$0 { appStore.trash.cancelPendingPurge() } }
            ),
            titleVisibility: .visible
        ) {
            Button(appStore.trash.pendingPurge == .all ? "Empty Trash" : "Delete Permanently", role: .destructive) {
                appStore.trash.confirmPendingPurge()
            }
            Button("Cancel", role: .cancel) {
                appStore.trash.cancelPendingPurge()
            }
        } message: {
            Text("You can't undo this action.")
        }
        .alert(
            "Automatic Organization Failed",
            isPresented: Binding(
                get: { appStore.jobs.batchTagFailure != nil },
                set: { if !$0 { appStore.jobs.batchTagFailure = nil } }
            )
        ) {
            Button("OK", role: .cancel) {
                appStore.jobs.batchTagFailure = nil
            }
        } message: {
            Text(appStore.jobs.batchTagFailure ?? "No tag system could be created.")
        }
    }

    private func withOverlays(_ content: some View) -> some View {
        content
        .overlay(alignment: .top) {
            VStack(spacing: 6) {
                // A failed library load is shown in the list itself, with Retry.
                if let error = bookmarkStore.draftStorageError {
                    StatusBanner(message: error)
                }
                if let error = AIConfigSync.shared.error {
                    StatusBanner(message: error)
                }
                if let msg = uiStateStore.errorMessage {
                    ToastView(kind: .error, message: msg) { uiStateStore.errorMessage = nil }
                        .transition(toastTransition(edge: .top))
                        .zIndex(100)
                }
                if let msg = uiStateStore.infoMessage {
                    ToastView(kind: .info, message: msg) { uiStateStore.infoMessage = nil }
                        .transition(toastTransition(edge: .top))
                        .zIndex(99)
                }
            }
            .padding(.top, 8)
            .animation(toastAnimation, value: uiStateStore.errorMessage)
            .animation(toastAnimation, value: uiStateStore.infoMessage)
        }
        .overlay(alignment: .bottom) {
            if let msg = uiStateStore.undoMessage {
                UndoToast(message: msg, duration: UIStateStore.undoWindow) {
                    uiStateStore.undoAction?()
                } onDismiss: {
                    uiStateStore.undoMessage = nil
                    uiStateStore.undoAction = nil
                }
                .id(uiStateStore.undoGeneration)
                .padding(.bottom, 20)
                .transition(toastTransition(edge: .bottom))
                .zIndex(99)
            }
        }
        .animation(toastAnimation, value: uiStateStore.undoMessage)
        .overlay {
            if showCommandPalette {
                CommandPaletteView(isPresented: $showCommandPalette)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .showImport)) { _ in showImport = true }
        .onReceive(NotificationCenter.default.publisher(for: .showCommandPalette)) { _ in showCommandPalette = true }
        .onReceive(NotificationCenter.default.publisher(for: .showAddBookmark)) { _ in showAddBookmark = true }
        .background(
            // Esc has no menu item, so it stays a window shortcut. While typing
            // it belongs to the field (clearing search, ending an edit).
            Group {
                if !showCommandPalette {
                    Button("") {
                        if let window = NSApp.keyWindow, LibraryCommandRouting.isEditingText(in: window) {
                            LibraryCommandRouting.forward(#selector(NSResponder.cancelOperation(_:)))
                        } else {
                            bookmarkStore.selectedIds.removeAll()
                            bookmarkStore.selectedBookmark = nil
                        }
                    }
                    .keyboardShortcut(.escape, modifiers: [])
                    .opacity(0)
                    .accessibilityHidden(true)
                }
            }
        )
    }

}

/// Transient feedback at the top of the window.
struct ToastView: View {
    enum Kind { case error, info }
    let kind: Kind
    let message: String
    let onDismiss: () -> Void

    private var tint: Color { kind == .error ? .red : .accentColor }
    private var icon: String { kind == .error ? "exclamationmark.triangle.fill" : "info.circle.fill" }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            Text(message)
                .font(.callout)
                .lineLimit(3)
                .textSelection(.enabled)
            Spacer(minLength: 8)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.caption.bold())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityLabel("Dismiss")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(tint.opacity(0.3), lineWidth: 1))
        .padding(.horizontal, 20)
        .shadow(color: .black.opacity(0.15), radius: 8, y: 4)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isStaticText)
    }
}

/// A condition that stays until it is resolved (note drafts can't be saved,
/// AI settings didn't sync) — same shape as a toast, without a dismiss button.
struct StatusBanner: View {
    let message: String

    var body: some View {
        Label {
            Text(message).font(.callout).textSelection(.enabled)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.orange.opacity(0.3), lineWidth: 1))
        .padding(.horizontal, 20)
    }
}

struct UndoToast: View {
    let message: String
    let duration: TimeInterval
    let onUndo: () -> Void
    let onDismiss: () -> Void

    @State private var startDate = Date()
    @State private var progress: Double = 1.0
    @State private var progressTask: Task<Void, Never>? = nil

    private var secondsLeft: Int {
        max(0, Int(ceil(duration * progress)))
    }

    var body: some View {
        HStack(spacing: 14) {
            // Countdown ring — how long undo stays available
            ZStack {
                Circle()
                    .stroke(Color.secondary.opacity(0.25), lineWidth: 3)
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text("\(secondsLeft)")
                    .font(.footnote.weight(.bold).monospacedDigit())
            }
            .frame(width: 30, height: 30)
            .accessibilityHidden(true)

            Text(message)
                .font(.body.weight(.semibold))
                .lineLimit(1)

            Spacer(minLength: 16)

            // Material, not the accent color, behind the text: white on a
            // yellow or orange accent was unreadable.
            Button(action: onUndo) {
                Label("Undo", systemImage: "arrow.uturn.backward")
            }
            .buttonStyle(.borderedProminent)

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.callout.weight(.bold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityLabel("Dismiss")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.secondary.opacity(0.2), lineWidth: 1))
        .shadow(color: .black.opacity(0.25), radius: 14, y: 6)
        .padding(.horizontal, 20)
        .accessibilityElement(children: .contain)
        .onAppear {
            startDate = Date()
            progress = 1.0
            progressTask?.cancel()
            progressTask = Task {
                while !Task.isCancelled {
                    let elapsed = Date().timeIntervalSince(startDate)
                    progress = max(0, 1 - elapsed / duration)
                    if progress <= 0 { break }
                    try? await Task.sleep(for: .milliseconds(100))
                }
            }
        }
        .onDisappear {
            progressTask?.cancel()
            progressTask = nil
        }
    }
}
