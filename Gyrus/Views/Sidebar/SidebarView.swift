import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct SidebarView: View {
    @Environment(AppStore.self) private var appStore
    @Environment(BookmarkStore.self) private var bookmarkStore
    @Environment(CollectionStore.self) private var collectionStore
    @Environment(TagStore.self) private var tagStore
    @Environment(UIStateStore.self) private var uiStateStore
    @Binding var showImport: Bool

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
                }
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
                    Task { try? await collectionStore.recolorCollection(folder.id, color: recolorFolderPick.toHex() ?? "#3B82F6") }
                    recolorFolder = nil
                },
                onCancel: { recolorFolder = nil }
            )
        }
    }

    // MARK: - Sub-areas

    @ViewBuilder
    private var bottomActionsArea: some View {
        VStack(spacing: 0) {
            if let status = uiStateStore.linkCheckStatus, status.running {
                LinkCheckProgressBar(status: status)
            }
            Divider()

            // Row 1: prominent "Check All Links"
            Button {
                Task { await appStore.startLinkCheck() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: uiStateStore.linkCheckStatus?.running == true
                          ? "antenna.radiowaves.left.and.right"
                          : "checkmark.shield.fill")
                        .foregroundStyle(Color.accentColor)
                    Text(uiStateStore.linkCheckStatus?.running == true ? "Checking links…" : "Check All Links")
                        .font(.callout.weight(.medium))
                    Spacer()
                    if uiStateStore.linkCheckStatus?.running != true {
                        Text("\(bookmarkStore.totalBookmarkCount)")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .monospacedDigit()
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(uiStateStore.linkCheckStatus?.running == true)
            .help("Finds dead links (404, timeout). Takes a few minutes for large collections.")

            Divider()

            // Row 2: Refresh Metadata — co-located with the link check so both
            // "freshen everything" passes live in one place. Kept separate
            // because a link check is a fast HEAD; metadata needs a full fetch.
            Button {
                Task { await appStore.startMetadataRefresh() }
            } label: {
                let running = uiStateStore.metadataRefreshStatus?.running == true
                HStack(spacing: 8) {
                    Image(systemName: running ? "arrow.triangle.2.circlepath" : "photo.on.rectangle.angled")
                        .foregroundStyle(.secondary)
                    Text(running ? "Refreshing metadata…" : "Refresh Metadata")
                        .font(.callout.weight(.medium))
                    Spacer()
                    if let s = uiStateStore.metadataRefreshStatus, s.running {
                        Text("\(s.processed)/\(s.total)")
                            .font(.caption2).foregroundStyle(.tertiary).monospacedDigit()
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(uiStateStore.metadataRefreshStatus?.running == true)
            .help("Re-fetches favicons, descriptions and preview images for every bookmark.")

            Divider()

            // Import / Export row
            HStack(spacing: 8) {
                Button {
                    showImport = true
                } label: {
                    Label("Import", systemImage: "square.and.arrow.down")
                        .font(.callout.weight(.medium))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Import bookmarks from a browser")

                Button {
                    showExportSheet = true
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                        .font(.callout.weight(.medium))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Export Bookmarks")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

}

// MARK: - Modifiers

struct SidebarSheetModifier: ViewModifier {
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
                        Task { _ = try? await tagStore.createTag(name: n, color: newTagColor.toHex()) }
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
                            _ = try? await tagStore.recolorTag(tag.id, color: hex)
                            // Recolor any open bookmark chips immediately.
                            bs.updateTagLocally(Tag(id: tag.id, name: tag.name, color: hex, createdAt: tag.createdAt))
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
        .background(.bar)
    }
}

// MARK: - Tag Editor Sheets

struct TagEditorSheet: View {
    let title: LocalizedStringKey
    @Binding var name: String
    @Binding var color: Color
    let onSave: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Text(title).font(.title3.bold())

            VStack(alignment: .leading, spacing: 6) {
                Text("Name").font(.callout.weight(.medium))
                TextField("e.g. important", text: $name)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Color").font(.callout.weight(.medium))
                HStack(spacing: 6) {
                    ForEach([Color.red, .orange, .yellow, .green, .teal, .blue, .purple, .pink], id: \.self) { preset in
                        Circle()
                            .fill(preset)
                            .frame(width: 22, height: 22)
                            .overlay(
                                Circle().strokeBorder(
                                    color.toHex() == preset.toHex() ? Color.primary : Color.clear,
                                    lineWidth: 2
                                )
                            )
                            .onTapGesture { color = preset }
                    }
                    Spacer()
                    ColorPicker("", selection: $color, supportsOpacity: false)
                        .labelsHidden()
                        .help("Custom color")
                }
            }

            HStack {
                Button("Cancel") { onCancel() }.buttonStyle(.bordered)
                Spacer()
                Button("Save") { onSave() }
                    .buttonStyle(.borderedProminent)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 360)
    }
}

struct ColorPickerSheet: View {
    let title: LocalizedStringKey
    @Binding var color: Color
    let onSave: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Text(title).font(.title3.bold())
            ColorPicker("Color", selection: $color, supportsOpacity: false)
            HStack {
                Button("Cancel") { onCancel() }.buttonStyle(.bordered)
                Spacer()
                Button("Save") { onSave() }.buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 320)
    }
}
