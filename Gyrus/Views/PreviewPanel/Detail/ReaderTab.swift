import SwiftUI
import AppKit

/// Reader state for the open bookmark. Lives in `BookmarkDetailView` (not in
/// `ReaderTab`) because the header's Copy/Translate buttons need it too, and
/// so switching Page modes does not throw away an already loaded text.
@MainActor
@Observable
final class ReaderModel {
    private(set) var content = ""
    private(set) var loadError: String?
    private(set) var isLoading = false
    private(set) var isCleaning = false
    private(set) var isTranslating = false
    private(set) var hasUsableContent = false
    private(set) var didCopy = false
    /// Which bookmark `content` belongs to. Every await re-checks it, so a
    /// slow response for the previous bookmark never lands on the new one.
    private var loadedBookmarkID: String?

    func reset() {
        content = ""
        loadError = nil
        isLoading = false
        isCleaning = false
        isTranslating = false
        hasUsableContent = false
        loadedBookmarkID = nil
    }

    func load(bookmarkID: String, force: Bool = false) async {
        guard force || loadedBookmarkID != bookmarkID else { return }
        loadedBookmarkID = bookmarkID
        content = ""
        loadError = nil
        hasUsableContent = false
        isLoading = true

        let extracted: String
        do {
            extracted = try await APIClient.shared.fetchReaderContent(id: bookmarkID)
        } catch {
            guard loadedBookmarkID == bookmarkID else { return }
            isLoading = false
            loadedBookmarkID = nil
            // Leaving the Reader cancels the load; that is not an error, the
            // next visit simply loads again.
            if !Task.isCancelled {
                loadError = Self.localizedError(error)
            }
            return
        }
        guard loadedBookmarkID == bookmarkID else { return }
        isLoading = false
        content = extracted
        hasUsableContent = true

        guard AppSettings.shared.aiBrainConfig.aiEnabled else { return }
        isCleaning = true
        do {
            let cleaned = try await APIClient.shared.cleanupReaderContent(
                id: bookmarkID,
                config: AppSettings.shared.aiBrainConfig
            )
            guard loadedBookmarkID == bookmarkID else { return }
            content = cleaned
        } catch {
            guard loadedBookmarkID == bookmarkID else { return }
            if !Task.isCancelled {
                AppStore.shared.uiStateStore.showError(error.localizedDescription)
            }
        }
        isCleaning = false
    }

    func translate(bookmarkID: String) {
        guard !isTranslating, loadedBookmarkID == bookmarkID else { return }
        isTranslating = true
        let source = content
        Task {
            defer { if loadedBookmarkID == bookmarkID { isTranslating = false } }
            do {
                let translated = try await APIClient.shared.translateReaderContent(
                    id: bookmarkID,
                    content: source,
                    targetLanguage: AppSettings.shared.effectiveLanguageCode,
                    config: AppSettings.shared.aiBrainConfig
                )
                guard loadedBookmarkID == bookmarkID else { return }
                content = translated
            } catch {
                guard loadedBookmarkID == bookmarkID else { return }
                AppStore.shared.uiStateStore.showError(error.localizedDescription)
            }
        }
    }

    func copy(title: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("\(title)\n\n\(content)", forType: .string)
        didCopy = true
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            didCopy = false
        }
    }

    /// The backend reports these failures in English; map the known ones to
    /// catalog strings so the Reader error reads in the app language.
    private static func localizedError(_ error: Error) -> String {
        switch error.localizedDescription {
        case "The page did not respond in time. Try again.":
            String(localized: "The page did not respond in time. Try again.")
        case "The page's security certificate could not be verified.":
            String(localized: "The page's security certificate could not be verified.")
        case "The page blocked access to its content.":
            String(localized: "The page blocked access to its content.")
        case "This type of page cannot be opened in Reader.":
            String(localized: "This type of page cannot be opened in Reader.")
        case "The page is too large to process safely.":
            String(localized: "The page is too large to process safely.")
        case "No readable content could be extracted from this page.":
            String(localized: "No readable content could be extracted from this page.")
        default:
            error.localizedDescription
        }
    }
}

// MARK: - Reader tab

/// Page → Reader: the extracted article text. Copy/Translate live in the
/// header's control row, so this view is content only.
struct ReaderTab: View {
    let bookmark: Bookmark
    let reader: ReaderModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if reader.isCleaning || reader.isTranslating {
                    let status: LocalizedStringKey = reader.isTranslating
                        ? "Translating…"
                        : "Formatting Reader with AI…"
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text(status)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                }

                if reader.isLoading {
                    ProgressView("Loading Reader…")
                        .frame(maxWidth: .infinity, minHeight: 180)
                } else if let loadError = reader.loadError {
                    ContentUnavailableView {
                        Label("Reader unavailable", systemImage: "doc.text.magnifyingglass")
                    } description: {
                        Text(loadError)
                    } actions: {
                        Button("Try Again") {
                            Task { await reader.load(bookmarkID: bookmark.id, force: true) }
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 240)
                } else {
                    ReaderFormattedContent(title: bookmark.title, content: reader.content)
                        .textSelection(.enabled)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task(id: bookmark.id) {
            await reader.load(bookmarkID: bookmark.id)
        }
    }
}
