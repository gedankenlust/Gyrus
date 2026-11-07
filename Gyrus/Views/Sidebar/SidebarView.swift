import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct SidebarView: View {
    @Environment(AppStore.self) private var appStore
    @Environment(BookmarkStore.self) private var bookmarkStore
    @Environment(CollectionStore.self) private var collectionStore
    @Environment(TagStore.self) private var tagStore
    @Environment(UIStateStore.self) private var uiStateStore

    @State private var selection: Set<String> = ["__all__"]
    @State private var showExportSheet = false
    @State private var exportFolder: Collection? = nil

    // New-tag dialog (presented via SidebarSheetModifier).
    @State private var showNewTag = false
    @State private var newTagName = ""
    @State private var newTagColor: Color = .blue

    // Tag recolor dialog (presented via SidebarMiscModifier).
    @State private var recolorTag: Tag? = nil
    @State private var recolorPick: Color = .blue

    // Folder recolor dialog.
    @State private var recolorFolder: Collection? = nil
    @State private var recolorFolderPick: Color = .blue

    var body: some View {
        // The AppKit outline view only rebuilds when THIS SwiftUI view re-renders,
        // so we must read every piece of data it displays here — otherwise e.g. a
        // tag's bookmark count changes in the store but the sidebar keeps showing
        // the stale number. Touch the read-status setting, the tag/folder lists,
        // and the sidebar counts so any change triggers a rebuild.
        let _ = AppSettings.shared.enableReadStatus
        let _ = tagStore.tags
        let _ = collectionStore.collections
        let _ = (bookmarkStore.totalBookmarkCount, bookmarkStore.trashCount,
                 bookmarkStore.deadBookmarkCount, bookmarkStore.unreadBookmarkCount)
        VStack(spacing: 0) {
            SidebarOutlineView(
                selection: $selection,
                store: collectionStore,
                tagStore: tagStore,
                bookmarkStore: bookmarkStore,
                onExport: { exportFolder = $0 },
                onNewTag: { newTagName = ""; newTagColor = .blue; showNewTag = true },
                onRecolorTag: { tag in
                    recolorPick = Color(hex: tag.color ?? "") ?? .blue
                    recolorTag = tag
                },
                onRecolorFolder: { folder in
                    recolorFolderPick = Color(hex: folder.color ?? "") ?? .accentColor
                    recolorFolder = folder
                },
                onDeleteTags: { tags in
                    Task { await appStore.deleteTags(tags) }
                },
                onMergeTags: { sources, target in
                    Task { await appStore.mergeTags(sources, into: target) }
                },
                onError: { appStore.surfaceError($0) }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            bottomActionsArea
        }
        .modifier(SidebarSheetModifier(
            showExportSheet: $showExportSheet,
            showNewTag: $showNewTag,
            newTagName: $newTagName,
            newTagColor: $newTagColor,
            tagStore: tagStore
        ))
        .modifier(SidebarMiscModifier(
            recolorTag: $recolorTag,
            recolorPick: $recolorPick,
            selection: $selection,
            collectionStore: collectionStore,
            tagStore: tagStore,
            bookmarkStore: bookmarkStore
        ))
        .navigationTitle("Gyrus")
        .onReceive(NotificationCenter.default.publisher(for: .showExport)) { _ in showExportSheet = true }
        .sheet(item: $exportFolder) { col in
            ExportSheet(
                isPresented: Binding(get: { exportFolder != nil },
                                     set: { if !$0 { exportFolder = nil } }),
                filterCollectionId: col.id,
                filterCollectionName: col.name
            )
        }
        .sheet(item: $recolorFolder) { folder in
            ColorPickerSheet(
                title: "Color for \"\(folder.name)\"",
                color: $recolorFolderPick,
                onSave: {
                    Task {
                        do { try await collectionStore.recolorCollection(folder.id, color: recolorFolderPick.toHex() ?? "#3B82F6") }
                        catch { appStore.surfaceError(error) }
                    }
                    recolorFolder = nil
                },
                onCancel: { recolorFolder = nil }
            )
        }
    }

    // MARK: - Sub-areas

    /// Library maintenance (link check, metadata refresh, import/export) lives
    /// in the Library menu. The sidebar only shows progress while a job runs,
    /// so the folder list keeps its space the rest of the time.
    @ViewBuilder
    private var bottomActionsArea: some View {
        let linkCheck = uiStateStore.linkCheckStatus.flatMap { $0.running ? $0 : nil }
        let metadata = uiStateStore.metadataRefreshStatus.flatMap { $0.running ? $0 : nil }
        if linkCheck != nil || metadata != nil {
            VStack(spacing: 0) {
                Divider()
                if let linkCheck {
                    LinkCheckProgressBar(status: linkCheck)
                }
                if let metadata {
                    MetadataRefreshProgressBar(status: metadata) {
                        Task { await appStore.cancelMetadataRefresh() }
                    }
                }
            }
        }
    }

}

struct MetadataRefreshProgressBar: View {
    let status: MetadataRefreshStatus
    let onStop: () -> Void

    var body: some View {
        let fraction = status.total > 0 ? Double(status.processed) / Double(status.total) : 0
        VStack(spacing: 4) {
            HStack {
                Text("Refreshing metadata… \(status.processed) / \(status.total)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Stop", action: onStop)
                    .buttonStyle(.borderless)
                    .controlSize(.mini)
                    .help("Already saved metadata is kept")
            }
            ProgressView(value: fraction)
                .progressViewStyle(.linear)
                .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}

// MARK: - Modifiers

struct SidebarSheetModifier: ViewModifier {
    @Environment(AppStore.self) private var appStore
    @Binding var showExportSheet: Bool
    @Binding var showNewTag: Bool
    @Binding var newTagName: String
    @Binding var newTagColor: Color
    let tagStore: TagStore

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $showExportSheet) {
                ExportSheet(isPresented: $showExportSheet)
            }
            .sheet(isPresented: $showNewTag) {
                TagEditorSheet(
                    title: "New Tag",
                    name: $newTagName,
                    color: $newTagColor,
                    onSave: {
                        let n = newTagName.trimmingCharacters(in: .whitespaces)
                        guard !n.isEmpty else { return }
                        Task {
                            do { _ = try await tagStore.createTag(name: n, color: newTagColor.toHex()) }
                            catch { appStore.surfaceError(error) }
                        }
                        showNewTag = false
                    },
                    onCancel: { showNewTag = false }
                )
            }
    }
}

struct SidebarMiscModifier: ViewModifier {
    @Environment(AppStore.self) private var appStore
    @Binding var recolorTag: Tag?
    @Binding var recolorPick: Color
    @Binding var selection: Set<String>
    let collectionStore: CollectionStore
    let tagStore: TagStore
    let bookmarkStore: BookmarkStore

    func body(content: Content) -> some View {
        content
            .sheet(item: $recolorTag) { tag in
                ColorPickerSheet(
                    title: "Color for \"\(tag.name)\"",
                    color: $recolorPick,
                    onSave: {
                        let hex = recolorPick.toHex() ?? "#3B82F6"
                        let bs = bookmarkStore
                        Task {
                            do {
                                _ = try await tagStore.recolorTag(tag.id, color: hex)
                                // Recolor any open bookmark chips immediately.
                                bs.updateTagLocally(Tag(id: tag.id, name: tag.name, color: hex, createdAt: tag.createdAt))
                            } catch { appStore.surfaceError(error) }
                        }
                        recolorTag = nil
                    },
                    onCancel: { recolorTag = nil }
                )
            }
            .onChange(of: selection) {
                if selection.count > 1 { return }
                let item = selection.first
                guard let item = item else { return }
                let mapped: String? = (item == "__all__") ? nil : item
                Task { await appStore.selectNavigation(id: mapped) }
            }
    }
}

// MARK: - Link-Check progress

struct LinkCheckProgressBar: View {
    let status: LinkCheckStatus

    var body: some View {
        let fraction = status.total > 0 ? Double(status.checked) / Double(status.total) : 0
        VStack(spacing: 4) {
            HStack {
                Text("Checking links… \(status.checked) / \(status.total)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                if status.deadFound > 0 {
                    Text("\(status.deadFound) dead")
                        .font(.caption2.bold())
                        .foregroundStyle(.red)
                }
            }
            ProgressView(value: fraction)
                .progressViewStyle(.linear)
                .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}

// MARK: - Tag Editor Sheets

struct TagEditorSheet: View {
    let title: LocalizedStringKey
    @Binding var name: String
    @Binding var color: Color
    let onSave: () -> Void
    let onCancel: () -> Void
    var errorMessage: String? = nil
    var isSaving = false

    private static let presets: [(Color, LocalizedStringKey)] = [
        (.red, "Red"), (.orange, "Orange"), (.yellow, "Yellow"), (.green, "Green"),
        (.teal, "Teal"), (.blue, "Blue"), (.purple, "Purple"), (.pink, "Pink"),
    ]

    private var canSave: Bool {
        !isSaving && !name.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(title).font(.title3.bold())

            Form {
                TextField("Name", text: $name, prompt: Text("e.g. important"))
                    .onSubmit { if canSave { onSave() } }
                LabeledContent("Color") {
                    HStack(spacing: 6) {
                        ForEach(Self.presets.indices, id: \.self) { index in
                            let (preset, label) = Self.presets[index]
                            let selected = color.toHex() == preset.toHex()
                            Button { color = preset } label: {
                                Circle()
                                    .fill(preset)
                                    .frame(width: 20, height: 20)
                                    .overlay(Circle().strokeBorder(selected ? Color.primary : .clear, lineWidth: 2))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(Text(label))
                            .accessibilityAddTraits(selected ? .isSelected : [])
                        }
                        ColorPicker("Custom Color", selection: $color, supportsOpacity: false)
                            .labelsHidden()
                            .help("Custom color")
                    }
                }
            }

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }

            SheetButtons(
                cancel: .cancel(onCancel),
                primary: SheetAction(title: "Save", isDisabled: !canSave, isWorking: isSaving, perform: onSave)
            )
        }
        .padding(20)
        .frame(width: 380)
    }
}

struct ColorPickerSheet: View {
    let title: LocalizedStringKey
    @Binding var color: Color
    let onSave: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(title).font(.title3.bold())
            ColorPicker("Color", selection: $color, supportsOpacity: false)
            SheetButtons(cancel: .cancel(onCancel), primary: SheetAction(title: "Save", perform: onSave))
        }
        .padding(20)
        .frame(width: 320)
    }
}
