import SwiftUI
import AppKit

/// The detail's only chrome strip: identity (favicon + title), the global
/// actions, and the controls for whatever is showing below. Everything that
/// used to be four stacked bars lives here, so content starts ~70pt from the
/// top instead of ~150pt.
struct DetailHeaderBar: View {
    let bookmark: Bookmark
    let tabs: [PreviewTab]
    @Binding var selectedTab: PreviewTab
    @Binding var pageMode: PreviewPageMode
    let controller: WebController
    let reader: ReaderModel
    let isLoadingDetails: Bool
    let onEdit: () -> Void

    private var aiEnabled: Bool { AppSettings.shared.aiBrainConfig.aiEnabled }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            titleRow
            // Try the labelled controls first; fall back to icons when the
            // inspector is too narrow (roughly below 420pt).
            ViewThatFits(in: .horizontal) {
                controlsRow(compact: false)
                controlsRow(compact: true)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    // MARK: Title row

    private var titleRow: some View {
        HStack(spacing: 8) {
            FaviconView(faviconPath: bookmark.faviconPath, bookmarkURL: bookmark.url, size: 16)
                .accessibilityHidden(true)
            Text(bookmark.displayTitle)
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(bookmark.displayTitle)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityAddTraits(.isHeader)

            if isLoadingDetails {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Loading details")
            }

            OpenInBrowserButton(url: bookmark.url, iconOnly: true)
                .buttonStyle(.borderless)
            overflowMenu
        }
    }

    private var overflowMenu: some View {
        Menu {
            Button(action: onEdit) {
                Label("Edit Bookmark…", systemImage: "pencil")
            }
            if AppSettings.shared.enableReadStatus {
                let readTitle: LocalizedStringKey = bookmark.isRead ? "Mark as Unread" : "Mark as Read"
                Button {
                    Task { await AppStore.shared.toggleRead(bookmark) }
                } label: {
                    Label(readTitle, systemImage: bookmark.isRead ? "envelope.badge" : "envelope.open")
                }
            }
            Divider()
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(bookmark.url, forType: .string)
            } label: {
                Label("Copy URL", systemImage: "doc.on.doc")
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("More Actions")
        .accessibilityLabel("More Actions")
    }

    // MARK: Controls row

    private func controlsRow(compact: Bool) -> some View {
        HStack(spacing: 8) {
            tabPicker(compact: compact)
                .fixedSize()
            Spacer(minLength: 0)
            if selectedTab == .page {
                pageModePicker
                switch pageMode {
                case .overview: EmptyView()
                case .reader: readerActions(compact: compact)
                case .live: webNavigation
                }
            }
        }
    }

    private func tabPicker(compact: Bool) -> some View {
        Picker("Preview Tab", selection: $selectedTab) {
            ForEach(tabs) { tab in
                Group {
                    if compact {
                        Image(systemName: tab.icon)
                            .accessibilityLabel(Text(tab.title))
                    } else {
                        Text(tab.title)
                    }
                }
                .tag(tab)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }

    /// A pop-up, not a second segmented control: the page modes are a
    /// sub-choice of the Page tab and should not compete with the tabs.
    private var pageModePicker: some View {
        Picker("Page View", selection: $pageMode) {
            ForEach(PreviewPageMode.allCases) { mode in
                Label(mode.title, systemImage: mode.icon).tag(mode)
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .fixedSize()
        .help("Page View")
    }

    @ViewBuilder
    private func readerActions(compact: Bool) -> some View {
        let copyTitle: LocalizedStringKey = reader.didCopy ? "Copied" : "Copy Text"
        Button {
            reader.copy(title: bookmark.title)
        } label: {
            Label(copyTitle, systemImage: reader.didCopy ? "checkmark" : "doc.on.doc")
                .labelStyle(ReaderActionLabelStyle(compact: compact))
        }
        .buttonStyle(.borderless)
        .disabled(!reader.hasUsableContent)
        .help("Copy the complete Reader text")
        .accessibilityLabel(copyTitle)

        if aiEnabled {
            Button {
                reader.translate(bookmarkID: bookmark.id)
            } label: {
                if reader.isTranslating {
                    ProgressView().controlSize(.small)
                } else {
                    Label("Translate", systemImage: "character.bubble")
                        .labelStyle(ReaderActionLabelStyle(compact: compact))
                }
            }
            .buttonStyle(.borderless)
            .disabled(reader.isCleaning || reader.isTranslating || !reader.hasUsableContent)
            .help("Translate the Reader text into the app language")
            .accessibilityLabel("Translate")
        }
    }

    private var webNavigation: some View {
        let reloadTitle: LocalizedStringKey = controller.isLoading ? "Stop Loading" : "Reload"
        return HStack(spacing: 4) {
            Button { controller.goBack() } label: { Image(systemName: "chevron.backward") }
                .disabled(!controller.canGoBack)
                .help("Back")
                .accessibilityLabel("Back")
            Button { controller.goForward() } label: { Image(systemName: "chevron.forward") }
                .disabled(!controller.canGoForward)
                .help("Forward")
                .accessibilityLabel("Forward")
            Button {
                controller.isLoading ? controller.stop() : controller.reload()
            } label: {
                Image(systemName: controller.isLoading ? "xmark" : "arrow.clockwise")
            }
            .help(reloadTitle)
            .accessibilityLabel(reloadTitle)
        }
        .buttonStyle(.borderless)
    }
}

/// Title and icon when there is room, icon only when the header is narrow.
private struct ReaderActionLabelStyle: LabelStyle {
    let compact: Bool

    func makeBody(configuration: Configuration) -> some View {
        if compact {
            configuration.icon
        } else {
            HStack(spacing: 4) {
                configuration.icon
                configuration.title
            }
        }
    }
}

// MARK: - Open in Browser

/// The single "Open in Browser" action of the detail. One icon everywhere
/// (header, web error state) so users learn to recognise it.
struct OpenInBrowserButton: View {
    static let icon = "safari"

    let url: String
    var iconOnly = false
    @Environment(BookmarkStore.self) private var bookmarkStore

    var body: some View {
        Button {
            bookmarkStore.safeBrowserOpen(url)
        } label: {
            if iconOnly {
                Label("Open in Browser", systemImage: Self.icon)
                    .labelStyle(.iconOnly)
            } else {
                Label("Open in Browser", systemImage: Self.icon)
            }
        }
        .help("Open in Browser")
        .accessibilityLabel("Open in Browser")
    }
}
