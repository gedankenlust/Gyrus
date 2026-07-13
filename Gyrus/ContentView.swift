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
    @State private var showBrainOnboarding = false
    @State private var newTagName = ""
    @State private var newTagColor: Color = .blue
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    private var confirmTitle: String {
        let n = uiStateStore.pendingBatchOpen?.count ?? 0
        return String(localized: "Open \(n) bookmarks at once?")
    }

    private var deleteConfirmTitle: String {
        let n = uiStateStore.pendingBatchDelete?.count ?? 0
        return String(localized: "Delete \(n) bookmarks?")
    }

    var body: some View {
        @Bindable var bookmarkStore = bookmarkStore
        @Bindable var uiStateStore = uiStateStore

        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(showImport: $showImport)
                .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 280)
        } content: {
            BookmarkListView(showAddBookmark: $showAddBookmark)
                .navigationSplitViewColumnWidth(min: 300, ideal: 420)
        } detail: {
            PreviewPanelView()
            .navigationSplitViewColumnWidth(min: 520, ideal: 720)
        }
        .sheet(isPresented: $showImport) {
            ImportWizardView(isPresented: $showImport)
        }
        .sheet(isPresented: $showAddBookmark) {
            AddBookmarkView(isPresented: $showAddBookmark)
        }
        .sheet(isPresented: $showBrainOnboarding) {
            BrainOnboardingView(isPresented: $showBrainOnboarding)
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
                    // Capture the typed values BEFORE resetting state — otherwise
                    // the async task would read the already-cleared name.
                    let name = newTagName.trimmingCharacters(in: .whitespaces)
                    let color = newTagColor.toHex()
                    if let ids = uiStateStore.newTagForIds, !name.isEmpty {
                        Task {
                            if let updated = try? await tagStore.createTagAndAssign(
                                name: name, color: color,
                                toBookmarkIds: ids, in: bookmarkStore.bookmarks) {
                                bookmarkStore.applyUpdated(updated)
                            }
                        }
                    }
                    uiStateStore.newTagForIds = nil
                    newTagName = ""
                },
                onCancel: { uiStateStore.newTagForIds = nil; newTagName = "" }
            )
        }
        .onAppear {
            // First launch only: offer to set up the optional AI Brain.
            if !AppSettings.shared.didCompleteBrainOnboarding {
                showBrainOnboarding = true
            }
        }
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
                get: { uiStateStore.pendingBatchDelete != nil },
                set: { if !$0 { appStore.cancelPendingDelete() } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete All", role: .destructive) {
                appStore.confirmPendingDelete()
            }
            Button("Cancel", role: .cancel) {
                appStore.cancelPendingDelete()
            }
        } message: {
            Text("This permanently deletes \(uiStateStore.pendingBatchDelete?.count ?? 0) bookmarks. You can undo for 5 seconds afterwards.")
        }
        .overlay(alignment: .top) {
            VStack(spacing: 6) {
                if let msg = uiStateStore.errorMessage {
                    ErrorToast(message: msg) { uiStateStore.errorMessage = nil }
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .animation(.spring(duration: 0.3), value: uiStateStore.errorMessage)
                        .zIndex(100)
                }
                if let msg = uiStateStore.infoMessage {
                    InfoToast(message: msg) { uiStateStore.infoMessage = nil }
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .animation(.spring(duration: 0.3), value: uiStateStore.infoMessage)
                        .zIndex(99)
                }
            }
            .padding(.top, 8)
        }
        .overlay(alignment: .bottom) {
            if let msg = uiStateStore.undoMessage {
                UndoToast(message: msg, duration: AppStore.undoWindow) {
                    uiStateStore.undoAction?()
                } onDismiss: {
                    uiStateStore.undoMessage = nil
                    uiStateStore.undoAction = nil
                }
                .id(uiStateStore.undoGeneration)
                .padding(.bottom, 20)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .animation(.spring(duration: 0.3), value: uiStateStore.undoMessage)
                .zIndex(99)
            }
        }
        .overlay {
            if showCommandPalette {
                CommandPaletteView(isPresented: $showCommandPalette)
            }
        }
        .sheet(item: Binding(
            get: { uiStateStore.batchTagReview },
            set: { uiStateStore.batchTagReview = $0 }
        )) { payload in
            TagReviewSheet(payload: payload) { discard in
                uiStateStore.batchTagReview = nil
                if !discard.isEmpty {
                    Task { await appStore.discardReviewedTags(discard) }
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .showImport)) { _ in showImport = true }
        .onReceive(NotificationCenter.default.publisher(for: .showCommandPalette)) { _ in showCommandPalette = true }
        .onReceive(NotificationCenter.default.publisher(for: .showAddBookmark)) { _ in showAddBookmark = true }
        .background(
            Group {
                Button("") { showCommandPalette.toggle() }
                    .keyboardShortcut("k", modifiers: .command)
                    .opacity(0)
                Button("") { showAddBookmark = true }
                    .keyboardShortcut("n", modifiers: .command)
                    .opacity(0)
                Button("") {
                    Task { await appStore.selectAllInCurrentView() }
                }
                .keyboardShortcut("a", modifiers: .command)
                .opacity(0)
                Button("") {
                    guard !bookmarkStore.selectedIds.isEmpty else { return }
                    appStore.requestOpenInBrowser(ids: bookmarkStore.selectedIds)
                }
                .keyboardShortcut("o", modifiers: .command)
                .opacity(0)
                Button("") {
                    guard !bookmarkStore.selectedIds.isEmpty else { return }
                    appStore.requestDeleteSelected()
                }
                .keyboardShortcut(.delete, modifiers: .command)
                .opacity(0)
                Button("") {
                    // ⌘Z runs the pending undo (same action as the undo toast),
                    // valid during the undo window after a delete/move.
                    if let undo = uiStateStore.undoAction {
                        undo()
                        uiStateStore.undoMessage = nil
                        uiStateStore.undoAction = nil
                    }
                }
                .keyboardShortcut("z", modifiers: .command)
                .opacity(0)
                if !showCommandPalette {
                    Button("") {
                        bookmarkStore.selectedIds.removeAll()
                        bookmarkStore.selectedBookmark = nil
                    }
                    .keyboardShortcut(.escape, modifiers: [])
                    .opacity(0)
                }
            }
        )
    }

}

struct ErrorToast: View {
    let message: String
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
            Text(message)
                .font(.callout)
                .lineLimit(2)
            Spacer()
            Button { onDismiss() } label: {
                Image(systemName: "xmark")
                    .font(.caption.bold())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.red.opacity(0.3), lineWidth: 1))
        .padding(.horizontal, 20)
        .shadow(color: .black.opacity(0.15), radius: 8, y: 4)
    }
}

struct InfoToast: View {
    let message: String
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "info.circle.fill")
                .foregroundStyle(.blue)
            Text(message)
                .font(.callout)
                .lineLimit(2)
            Spacer()
            Button { onDismiss() } label: {
                Image(systemName: "xmark")
                    .font(.caption.bold())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.blue.opacity(0.3), lineWidth: 1))
        .padding(.horizontal, 20)
        .shadow(color: .black.opacity(0.15), radius: 8, y: 4)
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
                    .stroke(Color.white.opacity(0.3), lineWidth: 3)
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(Color.white, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text("\(secondsLeft)")
                    .font(.footnote.weight(.bold).monospacedDigit())
                    .foregroundStyle(.white)
            }
            .frame(width: 32, height: 32)

            Image(systemName: "trash.fill")
                .foregroundStyle(.white.opacity(0.9))

            Text(message)
                .font(.body.weight(.semibold))
                .foregroundStyle(.white)
                .lineLimit(1)

            Spacer(minLength: 16)

            Button { onUndo() } label: {
                Label("Undo", systemImage: "arrow.uturn.backward")
                    .font(.body.weight(.bold))
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(Color.white, in: Capsule())
            }
            .buttonStyle(.plain)

            Button { onDismiss() } label: {
                Image(systemName: "xmark")
                    .font(.callout.weight(.bold))
                    .foregroundStyle(.white.opacity(0.75))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(Color.white.opacity(0.25), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.35), radius: 16, y: 6)
        .padding(.horizontal, 20)
        .onAppear {
            startDate = Date()
            progress = 1.0
            
            // Task-based progress updates
            progressTask?.cancel()
            progressTask = Task {
                while !Task.isCancelled {
                    let elapsed = Date().timeIntervalSince(startDate)
                    progress = max(0, 1 - elapsed / duration)
                    
                    if progress <= 0 { break }
                    
                    try? await Task.sleep(for: .milliseconds(50))
                }
            }
        }
        .onDisappear {
            progressTask?.cancel()
            progressTask = nil
        }
    }
}
