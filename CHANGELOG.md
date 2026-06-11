# Changelog

All notable changes to Gyrus are documented here.
Format loosely follows [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).

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
