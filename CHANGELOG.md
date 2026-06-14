# Changelog

All notable changes to Gyrus are documented here.
Format loosely follows [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).

---

## [0.9.0] – 2026-06-14

### Changed
- **Gyrus is now strictly local-only.** Removed the unfinished cloud LLM
  (OpenAI/Anthropic) provider option from Settings — the AI Brain runs entirely
  on your local Ollama model. Old configs that referenced "cloud" fall back to
  Ollama automatically.

### Hardened
- A full database snapshot is now **guaranteed before any schema migration**,
  independent of the once-a-day backup throttle. An update can never apply a
  migration without first leaving a fresh, recoverable copy.

### Docs
- README brought in line with what actually ships (semantic search, menu-bar
  quick-add) and the validated scale — smooth past 100,000 bookmarks.

---

## [0.8.0] – 2026-06-13

### Added
- **Menu-bar quick-add** — a Gyrus icon in the macOS menu bar to save a
  bookmark without opening the main window. The quick-add panel pre-fills the
  URL from your clipboard and drops it into the Inbox. Can be hidden in
  Settings → Behavior.
- **Global quick-add shortcut** (default ⌃⌥⌘B, freely configurable) — opens the
  quick-add panel from anywhere, even when Gyrus isn't frontmost.
- Hotkey settings now warn when a chosen combination is already in use.

### Fixed
- No more transient "Server error 404" toast when returning to the app after
  the Mac wakes from sleep — the background poll now waits for the backend to
  reconnect.
- Dragging a URL onto the grid now confirms success (or reports a duplicate)
  instead of failing silently.

---

## [0.7.1] – 2026-06-12

### Fixed
- Semantic-search vector index now stays in sync when bookmarks are trashed in
  bulk, restored, or purged (previously only single-delete cleaned up).
- Summarize and reindex now route through the shared API client instead of
  hardcoded URLs.
- Semantic search falls back to keyword search on errors instead of failing.
- The semantic-search toggle now appears automatically when Ollama is started
  after Gyrus is already running.
- Completed the German localization (no untranslated strings remaining).

---

## [0.7.0] – 2026-06-11

### Added
- **Semantic search** — meaning-based search powered by local embeddings
  (`nomic-embed-text` via Ollama). A sparkle-magnifying-glass toggle next to
  the search bar switches between keyword (FTS) and meaning mode. Falls back to
  keyword search silently when Ollama is unavailable.
- **Embedding index** — page content is indexed automatically in the background
  whenever a bookmark's Reader or AI chat is first opened.
- **Reindex button** (Settings → AI) — rebuilds the semantic index for all
  bookmarks that already have cached page content.
- **Summarize** — tap the quote icon in the AI Brain panel to generate a 2-3
  sentence summary of the current bookmark and save it as an AI note.
- `GET /api/search/semantic` and `GET /api/search/status` backend endpoints.
- `POST /api/brain/summarize/{id}` backend endpoint.

### Fixed
- Brain markdown filenames now include a short ID suffix to prevent collisions
  when two bookmarks share the same title in the same folder.
- `ScreenshotView.swift` renamed to `WebPreviewView.swift` (stale name from
  removed screenshot feature).

---

## [0.6.0] – 2026-06-10

### Added
- **Read / Unread** — mark bookmarks read or unread. Unread dot in list and
  card views, "Unread" smart view in the sidebar, toggle button in the detail
  panel. Feature can be turned off in Settings → Behavior.
- **Trash (soft delete)** — deleting a bookmark moves it to the Trash instead
  of removing it instantly. Restore individual items, drag bookmarks onto the
  Trash row, or use "Empty Trash". Items are purged automatically after 30 days.
- **Full-text content search** — search now matches words from the extracted
  article body, not just titles, URLs and tags.
- **Streaming AI chat** — replies appear token-by-token as they are generated.
- **Markdown formatting** in chat replies (lists, bold, code blocks).
- **Stop button** to cancel an in-progress reply.
- **Clear conversation** button in the AI Brain panel header.
- **"Tidy with AI"** button in the Reader tab — optional LLM reformatting of
  the extracted text; never modifies the cached original.

### Fixed
- Reader now preserves paragraphs, headings and list structure instead of
  flattening every inline element onto its own line.
- Cloud LLM option no longer returns a silent fake answer; raises a clear
  "not yet available" error instead.
- App version was stuck at 0.5.0 in the About panel — corrected to 0.6.0.
- `build_output.txt` (contained local paths) removed from the repository.

---

## [0.5.1] – 2026-06-07

### Added
- Open-source release on GitHub with public repository.
- `GETTING_STARTED.md` in English and German.

### Fixed
- Technical stability improvements and code cleanup.

---

## [0.5.0] – 2026-06-05

### Added
- Initial public release.
- Import / export (Netscape HTML — Brave, Arc, Chrome, Firefox, Safari).
- Folders and colored tags; drag to reorder and nest folders.
- AI Auto-Tags via local Ollama model.
- Full-text search (FTS5) over titles, URLs, descriptions, notes and tags.
- Global search hotkey (⌥ Space by default).
- Reader mode (article extraction via Readability).
- Multi-select and bulk actions.
- Live WKWebView preview.
- Dead-link detection with retry logic.
- Metadata refresh (favicons, OG images, descriptions).
- Per-bookmark Markdown notes.
- AI Brain: per-bookmark chat with a local LLM; mirrors bookmarks to Markdown
  files following the folder structure.
- Browser extension "Gyrus Saver" (Chrome/Brave/Arc/Edge).
- JSON backup and restore.
- Sorting and paginated lists.
