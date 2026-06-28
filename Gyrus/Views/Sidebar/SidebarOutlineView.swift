import SwiftUI
import AppKit

/// One node in the unified source list. A reference type so NSOutlineView keeps
/// stable identity (expansion/selection) across reloads; interned by `id`.
final class SidebarNode: NSObject {
    enum Kind {
        case special(title: String, symbol: String, tint: NSColor)
        case group(title: String, add: GroupAdd)
        case folder(Collection)
        case tag(Tag)
    }
    enum GroupAdd { case folder, tag, none }

    let id: String
    var kind: Kind
    var count: Int
    var children: [SidebarNode]

    init(id: String, kind: Kind, count: Int = 0, children: [SidebarNode] = []) {
        self.id = id; self.kind = kind; self.count = count; self.children = children
    }
}

/// The full sidebar as a native macOS source list (one NSOutlineView), so every
/// row — special items, folders, tags — shares the same selection pill, spacing
/// and native drag. Bridged into SwiftUI.
struct SidebarOutlineView: NSViewRepresentable {
    @Binding var selection: Set<String>
    let store: CollectionStore
    let tagStore: TagStore
    let bookmarkStore: BookmarkStore
    var onExport: (Collection) -> Void = { _ in }
    var onNewTag: () -> Void = {}
    var onRecolorTag: (Tag) -> Void = { _ in }
    var onRecolorFolder: (Collection) -> Void = { _ in }
    var onDeleteTags: ([Tag]) -> Void = { _ in }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let outline = NSOutlineView()
        outline.headerView = nil
        outline.rowHeight = 28
        outline.style = .sourceList
        outline.indentationPerLevel = 12
        outline.floatsGroupRows = false
        outline.allowsMultipleSelection = true
        outline.backgroundColor = .clear

        let column = NSTableColumn(identifier: .init("main"))
        column.resizingMask = .autoresizingMask
        outline.addTableColumn(column)
        outline.outlineTableColumn = column

        outline.dataSource = context.coordinator
        outline.delegate = context.coordinator
        outline.menu = context.coordinator.makeMenu()
        outline.registerForDraggedTypes([.string])
        outline.setDraggingSourceOperationMask(.move, forLocal: true)

        context.coordinator.outlineView = outline
        context.coordinator.rebuild()
        outline.reloadData()
        context.coordinator.expandGroups()

        let scroll = NSScrollView()
        scroll.documentView = outline
        scroll.hasVerticalScroller = true   // the sidebar fills the column; scroll when full
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.automaticallyAdjustsContentInsets = false
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard !context.coordinator.isDragging else { return }
        context.coordinator.reload()
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
        var parent: SidebarOutlineView
        weak var outlineView: NSOutlineView?
        var isDragging = false
        private var updatingSelection = false

        private var roots: [SidebarNode] = []
        private var interned: [String: SidebarNode] = [:]
        private var collectionsById: [String: Collection] = [:]

        init(_ parent: SidebarOutlineView) { self.parent = parent }

        // MARK: Build model

        @MainActor
        func rebuild() {
            collectionsById.removeAll()
            func indexCollections(_ list: [Collection]) {
                for c in list { collectionsById[c.id] = c; indexCollections(c.children) }
            }
            indexCollections(parent.store.collections)

            var newRoots: [SidebarNode] = []
            newRoots.append(node(id: "__all__",
                                 kind: .special(title: AppSettings.shared.localized("All Bookmarks"), symbol: "bookmark.fill", tint: .controlAccentColor),
                                 count: parent.bookmarkStore.totalBookmarkCount))
            if AppSettings.shared.enableReadStatus && parent.bookmarkStore.unreadBookmarkCount > 0 {
                newRoots.append(node(id: "__unread__",
                                     kind: .special(title: AppSettings.shared.localized("Unread"), symbol: "envelope.badge.fill", tint: .controlAccentColor),
                                     count: parent.bookmarkStore.unreadBookmarkCount))
            }
            if parent.bookmarkStore.deadBookmarkCount > 0 {
                newRoots.append(node(id: "__dead__",
                                     kind: .special(title: AppSettings.shared.localized("Dead Links"), symbol: "exclamationmark.triangle.fill", tint: .systemRed),
                                     count: parent.bookmarkStore.deadBookmarkCount))
            }
            let folders = node(id: "group:folders", kind: .group(title: AppSettings.shared.localized("Folders"), add: .folder))
            folders.children = folderNodes(parent.store.collections)
            newRoots.append(folders)

            let tags = node(id: "group:tags", kind: .group(title: AppSettings.shared.localized("Tags"), add: .tag))
            tags.children = parent.tagStore.tags.map { tag in
                node(id: "tag:\(tag.name)", kind: .tag(tag), count: tag.bookmarkCount)
            }
            newRoots.append(tags)

            // Trash is always shown (like Finder) so it's a predictable place to
            // recover deleted bookmarks — even when currently empty.
            newRoots.append(node(id: "__trash__",
                                 kind: .special(title: AppSettings.shared.localized("Trash"), symbol: "trash", tint: .secondaryLabelColor),
                                 count: parent.bookmarkStore.trashCount))

            roots = newRoots
            // Drop interned nodes that no longer exist.
            let live = Set(allIds(newRoots))
            interned = interned.filter { live.contains($0.key) }
        }

        private func folderNodes(_ cols: [Collection]) -> [SidebarNode] {
            cols.map { c in
                let n = node(id: c.id, kind: .folder(c), count: c.bookmarkCount)
                n.children = folderNodes(c.children)
                return n
            }
        }

        /// Intern by id so the same instance is reused (keeps expansion stable),
        /// but refresh its payload each rebuild.
        private func node(id: String, kind: SidebarNode.Kind, count: Int = 0) -> SidebarNode {
            if let existing = interned[id] {
                existing.kind = kind; existing.count = count; existing.children = []
                return existing
            }
            let n = SidebarNode(id: id, kind: kind, count: count)
            interned[id] = n
            return n
        }

        private func allIds(_ nodes: [SidebarNode]) -> [String] {
            nodes.flatMap { [$0.id] + allIds($0.children) }
        }

        // MARK: Data source

        func outlineView(_ ov: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
            (item as? SidebarNode)?.children.count ?? roots.count
        }
        func outlineView(_ ov: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
            (item as? SidebarNode)?.children[index] ?? roots[index]
        }
        func outlineView(_ ov: NSOutlineView, isItemExpandable item: Any) -> Bool {
            !((item as? SidebarNode)?.children.isEmpty ?? true)
        }
        func outlineView(_ ov: NSOutlineView, isGroupItem item: Any) -> Bool {
            if case .group = (item as? SidebarNode)?.kind { return true }
            return false
        }
        func outlineView(_ ov: NSOutlineView, shouldSelectItem item: Any) -> Bool {
            guard let node = item as? SidebarNode else { return false }
            if case .group = node.kind { return false }
            return true
        }
        /// Keep multi-selection meaningful: only tags can be selected together
        /// (for bulk delete). A Shift/Cmd range that mixes in a folder or a
        /// special item ("All Bookmarks") collapses to a single row instead.
        func outlineView(_ ov: NSOutlineView,
                         selectionIndexesForProposedSelection proposed: IndexSet) -> IndexSet {
            if proposed.count <= 1 { return proposed }
            func isTag(_ row: Int) -> Bool {
                if case .tag = (ov.item(atRow: row) as? SidebarNode)?.kind { return true }
                return false
            }
            var tagRows = IndexSet()
            for row in proposed where isTag(row) { tagRows.insert(row) }
            if tagRows.count >= 2 { return tagRows }
            // Not a multi-tag selection — fall back to the clicked (or first) row.
            let row = (ov.clickedRow >= 0 && proposed.contains(ov.clickedRow))
                ? ov.clickedRow : proposed.first!
            return IndexSet(integer: row)
        }
        /// Hide the disclosure triangle on the FOLDERS/TAGS headers. macOS shows
        /// it on hover at the trailing edge — right where our "+" sits — so users
        /// would click the collapse chevron instead of "Add". These sections are
        /// always expanded, so the control is unnecessary anyway.
        func outlineView(_ ov: NSOutlineView, shouldShowOutlineCellForItem item: Any) -> Bool {
            if case .group = (item as? SidebarNode)?.kind { return false }
            return true
        }
        func outlineView(_ ov: NSOutlineView, shouldCollapseItem item: Any) -> Bool {
            if case .group = (item as? SidebarNode)?.kind { return false }
            return true
        }

        // MARK: Cells

        func outlineView(_ ov: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
            guard let n = item as? SidebarNode else { return nil }
            switch n.kind {
            case .group(let title, let add):
                let id = NSUserInterfaceItemIdentifier("Group")
                let cell = (ov.makeView(withIdentifier: id, owner: self) as? GroupCellView) ?? {
                    let c = GroupCellView(); c.identifier = id; return c
                }()
                cell.configure(title: title, showAdd: add != .none, target: self,
                               action: add == .folder ? #selector(addFolderRoot) : #selector(addTag))
                return cell
            case .special(let title, let symbol, let tint):
                return itemCell(ov, symbol: symbol, tint: tint, name: title, count: n.count)
            case .folder(let c):
                return itemCell(ov, symbol: "folder.fill", tint: nsColor(hex: c.color), name: c.name, count: n.count)
            case .tag(let t):
                let id = NSUserInterfaceItemIdentifier("Tag")
                let cell = (ov.makeView(withIdentifier: id, owner: self) as? TagCellView) ?? {
                    let c = TagCellView(); c.identifier = id; return c
                }()
                cell.configure(name: t.name, color: nsColor(hex: t.color), count: n.count)
                return cell
            }
        }

        private func itemCell(_ ov: NSOutlineView, symbol: String, tint: NSColor, name: String, count: Int) -> NSView {
            let id = NSUserInterfaceItemIdentifier("Item")
            let cell = (ov.makeView(withIdentifier: id, owner: self) as? ItemCellView) ?? {
                let c = ItemCellView(); c.identifier = id; return c
            }()
            cell.configure(symbol: symbol, tint: tint, name: name, count: count)
            return cell
        }

        // MARK: Selection

        func outlineViewSelectionDidChange(_ notification: Notification) {
            guard !updatingSelection, let ov = outlineView else { return }
            let rows = ov.selectedRowIndexes
            guard !rows.isEmpty else { return }
            // Push the FULL selection into the binding. A single tag/folder drives
            // navigation; a multi-tag selection is carried through too (SidebarView
            // ignores sets with count > 1 for navigation) so it survives reloads.
            let ids = rows.compactMap { (ov.item(atRow: $0) as? SidebarNode)?.id }
            if !ids.isEmpty { parent.selection = Set(ids) }
        }

        private func syncSelection(in ov: NSOutlineView) {
            updatingSelection = true; defer { updatingSelection = false }
            let rows = parent.selection.compactMap { id -> Int? in
                guard let n = interned[id] else { return nil }
                let row = ov.row(forItem: n)
                return row >= 0 ? row : nil
            }
            if rows.isEmpty { ov.deselectAll(nil); return }
            ov.selectRowIndexes(IndexSet(rows), byExtendingSelection: false)
        }

        // MARK: Expansion + height

        func expandGroups() {
            guard let ov = outlineView else { return }
            for n in roots { if case .group = n.kind { ov.expandItem(n) } }
            // Expand folders that have children.
            func expand(_ nodes: [SidebarNode]) {
                for n in nodes where !n.children.isEmpty { ov.expandItem(n); expand(n.children) }
            }
            expand(roots)
        }

        @MainActor
        func reload() {
            guard let ov = outlineView else { return }
            let expanded = Set(interned.values.filter { ov.isItemExpanded($0) }.map { $0.id })
            rebuild()
            ov.reloadData()
            for id in expanded { if let n = interned[id] { ov.expandItem(n) } }
            expandGroups()
            syncSelection(in: ov)
        }

        // MARK: Drag & drop (folders only)

        func outlineView(_ ov: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
            guard let n = item as? SidebarNode, case .folder(let c) = n.kind else { return nil }
            let p = NSPasteboardItem(); p.setString("col:\(c.id)", forType: .string); return p
        }
        func outlineView(_ ov: NSOutlineView, draggingSession session: NSDraggingSession,
                         willBeginAt screenPoint: NSPoint, forItems draggedItems: [Any]) { isDragging = true }
        func outlineView(_ ov: NSOutlineView, draggingSession session: NSDraggingSession,
                         endedAt screenPoint: NSPoint, operation: NSDragOperation) { isDragging = false }

        /// nil = not a valid folder target; otherwise the destination parent id
        /// (nil-wrapped distinction handled by the Bool return).
        private func folderTarget(_ item: Any?) -> (valid: Bool, parentId: String?) {
            guard let n = item as? SidebarNode else { return (false, nil) }
            switch n.kind {
            case .folder(let c): return (true, c.id)
            case .group(_, let add) where add == .folder: return (true, nil) // Folders group → root
            default: return (false, nil)
            }
        }

        func outlineView(_ ov: NSOutlineView, validateDrop info: NSDraggingInfo,
                         proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation {
            guard let str = info.draggingPasteboard.string(forType: .string) else { return [] }
            let target = folderTarget(item)

            if str.hasPrefix("col:") {
                guard target.valid else { return [] }
                let movedId = String(str.dropFirst(4))
                if movedId == target.parentId { return [] }
                if isDescendant(target.parentId, ofOrEqual: movedId) { return [] }
                return .move
            }
            // Bookmarks: onto a folder row (move) or the Trash row (delete).
            if index == NSOutlineViewDropOnItemIndex {
                if case .folder = (item as? SidebarNode)?.kind { return .move }
                if (item as? SidebarNode)?.id == "__trash__" { return .move }
            }
            return []
        }

        func outlineView(_ ov: NSOutlineView, acceptDrop info: NSDraggingInfo,
                         item: Any?, childIndex index: Int) -> Bool {
            guard let str = info.draggingPasteboard.string(forType: .string) else { return false }
            let target = folderTarget(item)
            isDragging = false

            if str.hasPrefix("col:") {
                guard target.valid else { return false }
                let movedId = String(str.dropFirst(4))
                let idx = (index == NSOutlineViewDropOnItemIndex) ? -1 : index
                let store = parent.store
                Task { @MainActor in store.moveFolder(movedId, toParent: target.parentId, atIndex: idx); self.reload() }
                return true
            }
            // Drop bookmarks onto the Trash row → move them to the Trash.
            if (item as? SidebarNode)?.id == "__trash__" {
                let ids = Set(str.split(separator: "\n").map(String.init))
                Task { @MainActor in
                    await AppStore.shared.trashBookmarks(ids: ids)
                    self.reload()
                }
                return true
            }

            guard case .folder(let c)? = (item as? SidebarNode)?.kind else { return false }
            let ids = Set(str.split(separator: "\n").map(String.init))
            Task { @MainActor in
                // Routes through AppStore so the current bookmark view reloads
                // and the moved bookmarks leave the open folder immediately.
                await AppStore.shared.moveBookmarks(ids: ids, to: c.id)
                self.reload()
            }
            return true
        }

        private func isDescendant(_ ancestorId: String?, ofOrEqual nodeId: String) -> Bool {
            var cursor = ancestorId
            while let c = cursor {
                if c == nodeId { return true }
                cursor = collectionsById[c]?.parentId
            }
            return false
        }

        // MARK: Context menu + actions

        func makeMenu() -> NSMenu { let m = NSMenu(); m.delegate = self; return m }

        private func clickedNode() -> SidebarNode? {
            guard let ov = outlineView, ov.clickedRow >= 0 else { return nil }
            return ov.item(atRow: ov.clickedRow) as? SidebarNode
        }
        private func clickedFolder() -> Collection? {
            if case .folder(let c)? = clickedNode()?.kind { return c }
            return nil
        }
        private func clickedTag() -> Tag? {
            if case .tag(let t)? = clickedNode()?.kind { return t }
            return nil
        }
        private func selectedTags() -> [Tag] {
            guard let ov = outlineView else { return [] }
            return ov.selectedRowIndexes.compactMap { row in
                guard let n = ov.item(atRow: row) as? SidebarNode,
                      case .tag(let t) = n.kind else { return nil }
                return t
            }
        }

        @objc func addFolderRoot() {
            if let name = promptText("New Folder", initial: "") {
                let store = parent.store
                Task { @MainActor in try? await store.createCollection(name: name, parentId: nil) }
            }
        }
        @objc func addTag() { parent.onNewTag() }

        @objc private func newSubfolder() {
            guard let c = clickedFolder() else { return }
            if let name = promptText("New Subfolder", initial: "") {
                let store = parent.store
                Task { @MainActor in try? await store.createCollection(name: name, parentId: c.id) }
            }
        }
        @objc private func renameFolder() {
            guard let c = clickedFolder() else { return }
            if let name = promptText("Rename Folder", initial: c.name), name != c.name {
                let store = parent.store
                Task { @MainActor in try? await store.renameCollection(c.id, newName: name) }
            }
        }
        @objc private func moveFolderToRoot() {
            guard let c = clickedFolder() else { return }
            let store = parent.store
            Task { @MainActor in try? await store.moveCollection(c.id, toParent: nil) }
        }
        @objc private func exportFolder() {
            guard let c = clickedFolder() else { return }
            parent.onExport(c)
        }
        @objc private func recolorFolder() {
            if let c = clickedFolder() { parent.onRecolorFolder(c) }
        }
        @objc private func deleteFolder() {
            guard let c = clickedFolder() else { return }
            if confirm("Delete \"\(c.name)\"?", "The bookmarks inside are kept — they just lose their folder assignment.") {
                let store = parent.store
                Task { @MainActor in _ = try? await store.deleteCollection(c.id) }
            }
        }
        @objc private func recolorTag() {
            if let t = clickedTag() { parent.onRecolorTag(t) }
        }
        @objc private func renameTag() {
            guard let t = clickedTag() else { return }
            if let name = promptText("Rename Tag", initial: t.name), name != t.name {
                let ts = parent.tagStore
                let bs = parent.bookmarkStore
                Task { @MainActor in
                    try? await ts.renameTag(t.id, newName: name)
                    // Reflect the new name on any open bookmark chips immediately.
                    bs.updateTagLocally(Tag(id: t.id, name: name, color: t.color, createdAt: t.createdAt))
                }
            }
        }
        @objc private func deleteTag() {
            guard let t = clickedTag() else { return }
            if confirm("Delete tag \"\(t.name)\"?", "Bookmarks keep their other tags. You can undo this.") {
                parent.onDeleteTags([t])
            }
        }
        @objc private func deleteSelectedTags() {
            let tags = selectedTags()
            guard !tags.isEmpty else { return }
            let msg = tags.count == 1
                ? "Delete tag \"\(tags[0].name)\"?"
                : "Delete \(tags.count) tags?"
            if confirm(msg, "Bookmarks keep their other tags. You can undo this.") {
                parent.onDeleteTags(tags)
            }
        }

        private func promptText(_ title: String, initial: String) -> String? {
            let alert = NSAlert()
            alert.messageText = title
            let tf = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
            tf.stringValue = initial
            alert.accessoryView = tf
            alert.addButton(withTitle: "OK"); alert.addButton(withTitle: "Cancel")
            let ok = alert.runModal() == .alertFirstButtonReturn
            let value = tf.stringValue.trimmingCharacters(in: .whitespaces)
            return (ok && !value.isEmpty) ? value : nil
        }
        private func confirm(_ title: String, _ message: String) -> Bool {
            let alert = NSAlert()
            alert.messageText = title; alert.informativeText = message
            alert.addButton(withTitle: "Delete"); alert.addButton(withTitle: "Cancel")
            return alert.runModal() == .alertFirstButtonReturn
        }

        private func nsColor(hex: String?) -> NSColor {
            if let hex, let c = Color(hex: hex) { return NSColor(c) }
            return .controlAccentColor
        }
    }
}

extension SidebarOutlineView.Coordinator: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let node = clickedNode() else { return }
        switch node.kind {
        case .folder(let c):
            menu.addItem(withTitle: "New Subfolder", action: #selector(newSubfolder), keyEquivalent: "")
            menu.addItem(withTitle: "Rename", action: #selector(renameFolder), keyEquivalent: "")
            if c.parentId != nil {
                menu.addItem(withTitle: "Move to Root", action: #selector(moveFolderToRoot), keyEquivalent: "")
            }
            menu.addItem(withTitle: "Change Color…", action: #selector(recolorFolder), keyEquivalent: "")
            menu.addItem(withTitle: "Export Folder…", action: #selector(exportFolder), keyEquivalent: "")
            menu.addItem(.separator())
            menu.addItem(withTitle: "Delete", action: #selector(deleteFolder), keyEquivalent: "")
        case .tag:
            let sel = selectedTags()
            // Only offer bulk delete when the right-clicked tag is part of the
            // current multi-selection; otherwise act on the clicked tag alone.
            let clickedInSelection = (outlineView?.clickedRow).map {
                outlineView?.selectedRowIndexes.contains($0) ?? false
            } ?? false
            if sel.count > 1 && clickedInSelection {
                menu.addItem(withTitle: "Delete \(sel.count) Tags", action: #selector(deleteSelectedTags), keyEquivalent: "")
            } else {
                menu.addItem(withTitle: "Rename", action: #selector(renameTag), keyEquivalent: "")
                menu.addItem(withTitle: "Change Color…", action: #selector(recolorTag), keyEquivalent: "")
                menu.addItem(.separator())
                menu.addItem(withTitle: "Delete", action: #selector(deleteTag), keyEquivalent: "")
            }
        default:
            return
        }
        for item in menu.items where item.action != nil { item.target = self }
    }
}

// MARK: - Cells

/// Section header: uppercase label + optional "+" button.
final class GroupCellView: NSTableCellView {
    private let label = NSTextField(labelWithString: "")
    private let add = NSButton()
    override init(frame: NSRect) {
        super.init(frame: frame)
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        add.bezelStyle = .inline
        add.isBordered = false
        add.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "Add")
        add.imagePosition = .imageOnly
        add.contentTintColor = .secondaryLabelColor
        add.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label); addSubview(add)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            add.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            add.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
    func configure(title: String, showAdd: Bool, target: AnyObject, action: Selector) {
        label.stringValue = title.uppercased()
        add.isHidden = !showAdd
        add.target = target; add.action = action
    }
}

/// Item row: tinted symbol + name + trailing count.
final class ItemCellView: NSTableCellView {
    private let icon = NSImageView()
    private let name = NSTextField(labelWithString: "")
    private let count = NSTextField(labelWithString: "")
    override init(frame: NSRect) {
        super.init(frame: frame)
        icon.translatesAutoresizingMaskIntoConstraints = false
        name.font = .systemFont(ofSize: 13)
        name.lineBreakMode = .byTruncatingTail
        name.translatesAutoresizingMaskIntoConstraints = false
        count.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        count.textColor = .secondaryLabelColor
        count.translatesAutoresizingMaskIntoConstraints = false
        addSubview(icon); addSubview(name); addSubview(count)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            name.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            name.centerYAnchor.constraint(equalTo: centerYAnchor),
            count.leadingAnchor.constraint(greaterThanOrEqualTo: name.trailingAnchor, constant: 6),
            count.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            count.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }
    required init?(coder: NSCoder) { fatalError() }
    func configure(symbol: String, tint: NSColor, name: String, count: Int) {
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        icon.contentTintColor = tint
        self.name.stringValue = name
        self.count.stringValue = count > 0 ? count.formatted() : ""
    }
}

/// Tag row: color dot + name.
final class TagCellView: NSTableCellView {
    private let dot = NSView()
    private let name = NSTextField(labelWithString: "")
    private let count = NSTextField(labelWithString: "")
    override init(frame: NSRect) {
        super.init(frame: frame)
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 5
        dot.translatesAutoresizingMaskIntoConstraints = false
        name.font = .systemFont(ofSize: 13)
        name.lineBreakMode = .byTruncatingTail
        name.translatesAutoresizingMaskIntoConstraints = false
        count.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        count.textColor = .secondaryLabelColor
        count.translatesAutoresizingMaskIntoConstraints = false
        addSubview(dot); addSubview(name); addSubview(count)
        NSLayoutConstraint.activate([
            dot.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 5),
            dot.centerYAnchor.constraint(equalTo: centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: 10),
            dot.heightAnchor.constraint(equalToConstant: 10),
            name.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 8),
            name.centerYAnchor.constraint(equalTo: centerYAnchor),
            count.leadingAnchor.constraint(greaterThanOrEqualTo: name.trailingAnchor, constant: 6),
            count.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            count.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }
    required init?(coder: NSCoder) { fatalError() }
    func configure(name: String, color: NSColor, count: Int) {
        self.name.stringValue = name
        dot.layer?.backgroundColor = color.cgColor
        self.count.stringValue = count > 0 ? count.formatted() : ""
    }
}
