# Changelog

All notable changes to Gyrus are documented here.
Format loosely follows [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).

---

## [1.0.0] – 2026-06-23

First stable release. Gyrus is a complete, fast, local-first bookmark manager —
and now AI is cleanly optional, on top.

### Added
- **One master "Enable AI" switch.** AI is **off by default**: Gyrus is a full
  bookmark manager with zero AI surface until you opt in. Turn it on and the
  whole local-AI stack appears — auto-tagging, semantic search, summaries and
  the AI Brain. The Markdown mirror is a sub-option under it.
- **Bulk AI auto-tagging.** Select many (or all) bookmarks and generate tags in
  one background pass — from the selection bar or the right-click menu.
- **Choose your Ollama models in Settings.** Separate pickers for the text model
  (chat/tags/summaries) and the embedding model (semantic search), each showing
  only the models that fit. Switching the embedding model rebuilds the vector
  index to match (so multilingual models like `bge-m3` work).
- **Richer AI Brain notes.** Each bookmark's Markdown file now carries
  frontmatter tags, description, AI summary, notes and `[[wikilinks]]` — a real
  Obsidian-ready knowledge graph. With a "Show in Finder" / "Open Index" shortcut.
- **⌘Z** undoes the last delete/move. **Resizable** list columns.
- **"Mark as working"** clears a dead-link false positive (one or many at once).
- A **Refresh Metadata** action next to the link check.

### Changed
- Auto-tags get varied, stable colors and prefer a few broad, reusable topics
  over many hyper-specific ones.
- Toolbar decluttered: semantic search moved into the search field; clearer
  model pickers; compact Data settings.

### Fixed
- **In-app language switching now translates the whole UI** (sidebar, titles,
  search field) — previously parts stayed in the system language.
- Favicons resolve on sub-path project sites (`user.github.io/project/`).
- `localhost` / private-LAN URLs are never flagged as dead links.

### Security
- The local backend rejects cross-site (web-page) requests, so no website you
  visit can drive it — carried over from 0.9.1.

---

## [0.9.1] – 2026-06-16

### Security
- **Blocked cross-site requests to the local backend.** A website you visited
  could previously fire a bodyless request (e.g. `factory-reset`) at the backend
  on `127.0.0.1` and wipe your data — CORS only stops reading the response, not
  the side effect. The backend now rejects any web-page Origin; only the browser
  extension and the app itself are allowed.

### Fixed
- `localhost` / private-LAN URLs are no longer flagged as dead links — a stopped
  local dev server is not a dead link. Existing false positives clear on the
  next check.
- Favicons are now found on project sites served under a sub-path (e.g.
  `user.github.io/project/`), which previously 404'd at the domain root.

---

## [0.9.0] – 2026-06-16

### Added
- **Bookmark counts next to tags** in the sidebar, matching the folder counts —
  so you can see at a glance how many bookmarks carry each tag (trashed ones are
  not counted).

### Changed
- **Gyrus is now strictly local-only.** Removed the unfinished cloud LLM
  (OpenAI/Anthropic) provider option from Settings — the AI Brain runs entirely
  on your local Ollama model. Old configs that referenced "cloud" fall back to
  Ollama automatically.

### Fixed
- No more transient "Server error 404" toast when returning to the app: a
  background list/count refresh that briefly hits the backend mid-restart is now
  silently retried instead of alarming you.
- Sidebar counts (tags and folders) now refresh immediately when they change —
  e.g. trashing a tagged bookmark drops that tag's count right away instead of
  showing a stale number.

### Hardened
- A full database snapshot is now **guaranteed before any schema migration**,
  independent of the once-a-day backup throttle. An update can never apply a
  migration without first leaving a fresh, recoverable copy.

### Docs
- README brought in line with what actually ships (semantic search, menu-bar
  quick-add) and the validated scale — smooth past 100,000 bookmarks.
- Clarified that the browser extension saves in the background: once Gyrus has
  been launched, its local backend keeps running, so you can save from your
  browser even with the Gyrus window closed.

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
