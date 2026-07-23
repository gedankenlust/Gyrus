<div align="center">

<img src="docs/icon.png" width="128" alt="Gyrus app icon">

# Gyrus

<p>
  Gyrus is a private, local-first macOS workspace for collecting and organizing
  useful web pages, reading articles without clutter, inspecting responsive
  designs, taking notes, and asking questions with optional local AI. Your
  bookmarks, extracted content, notes, and conversations stay on your Mac
  without an account, cloud sync, or telemetry.
</p>

[![Platform](https://img.shields.io/badge/platform-macOS%2026%2B-black?logo=apple)](#requirements) [![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE) [![Status](https://img.shields.io/badge/status-Early%20Preview-f59e0b.svg?style=flat-square)](#project-status) [![Version](https://img.shields.io/badge/version-1.4.0--beta.1-f59e0b.svg?style=flat-square)](#project-status) [![Built with Swift](https://img.shields.io/badge/Swift-SwiftUI-fa7343?logo=swift&logoColor=white&style=flat-square)](https://developer.apple.com/swiftui/) [![Backend: FastAPI](https://img.shields.io/badge/backend-FastAPI-009688?logo=fastapi&logoColor=white&style=flat-square)](https://fastapi.tiangolo.com/)

[**Download Early Preview**](https://github.com/gedankenlust/Gyrus/releases/tag/v1.4.0-beta.1) · [Stable releases](https://github.com/gedankenlust/Gyrus/releases/latest) · [Features](#features) · [Browser extension](#browser-extension) · [AI Brain](#ai-brain-optional) · [Build](#building-from-source)

</div>

---

> New here? [GETTING_STARTED.md](GETTING_STARTED.md) contains a complete
> English and German walkthrough.

## What is Gyrus?

<p align="center">
  <img src="docs/screenshots/main.png" width="900" alt="Gyrus main window">
</p>

Gyrus is a native macOS app for people who collect useful links and want to do
more than leave them in an endless list. It combines a fast bookmark library,
a focused reader, a browser-based design inspector, notes, and an optional
local AI workspace.

Every selected bookmark opens into four clear top-level areas:

1. **Page** — metadata, a formatted Reader, and the live website.
2. **Design** — responsive rendering and inspectable design evidence.
3. **AI Brain** — page-grounded chat using your local Ollama model.
4. **Notes** — editable notes stored with the bookmark.

AI is optional. With AI disabled, Gyrus remains a complete local bookmark,
reading, and web-inspection app.

## Download and install

Download **`Gyrus.dmg`** from the
[current Early Preview](https://github.com/gedankenlust/Gyrus/releases/tag/v1.4.0-beta.1),
open it, and drag Gyrus into Applications. The latest non-preview build remains
available under [stable releases](https://github.com/gedankenlust/Gyrus/releases/latest).

Gyrus is distributed with an ad-hoc signature because the project does not use
a paid Apple Developer membership. On first launch after each update:

- On current macOS versions, try opening Gyrus once, then go to
  **System Settings → Privacy & Security → Open Anyway**.
- On older macOS versions, Control-click Gyrus in Applications, choose
  **Open**, and confirm.

The released app is self-contained. Its local FastAPI backend, Python runtime,
and headless Chromium are included; users do not install Python, Playwright, or
a browser separately. The app bundle is roughly 490 MB, while the compressed
DMG is smaller.

## Why Gyrus?

- **Local-first.** Bookmarks live in SQLite on your Mac and can be exported at
  any time.
- **Native.** SwiftUI and AppKit provide a responsive three-column workspace,
  native selection, drag and drop, keyboard commands, and a menu-bar quick add.
- **Useful for web design.** Compare real desktop, tablet, and mobile renders;
  inspect colors, type, components, assets, layout, SEO, accessibility,
  network requests, and console output.
- **Grounded local AI.** Gyrus supplies the model with extracted article text,
  structured data, site structure, and captured design evidence instead of
  asking it to guess.
- **Open source.** The Swift app, Python backend, browser companion, migrations,
  tests, and release scripts are all in this repository.

## Features

| Area | What it does |
|---|---|
| **Library** | List or grid view, folders, colored tags, Trash, sorting, pagination, resizable columns, and multi-selection |
| **Import and export** | Netscape bookmark HTML for Brave, Arc, Chrome, Firefox, and Safari; portable JSON backup and restore |
| **Search** | SQLite FTS5 over titles, URLs, tags, notes, and AI chats; global `⌥ Space` command palette |
| **Tag assignment** | Assign existing tags to one or many bookmarks and preserve every manually assigned tag |
| **Reviewable tag system** | With AI enabled, analyze 10 or more bookmarks together, review a proposed taxonomy, rename or remove categories, then apply it |
| **Page workspace** | Overview, structured Reader, translation, complete text copy, and a live `WKWebView` |
| **Design workspace** | Bundled Chromium captures desktop `1440×1200`, tablet `834×1112`, and mobile `390×844` views |
| **Design evidence** | Colors, typography, components, layout, assets, SEO, accessibility, network, console, raw DOM/CSS evidence, and viewport PDF export |
| **Notes** | Per-bookmark notes with auto-save |
| **AI Brain** | Persistent page-grounded conversations, summaries, site-structure awareness, and optional Markdown mirroring |
| **Link maintenance** | Background dead-link checks, manual status correction, metadata refresh, favicons, descriptions, and preview images |
| **Browser extension** | Gyrus Saver sends the active browser tab to the Inbox and enriches it in the background |
| **Quick add** | Menu-bar command and configurable global shortcut save a URL without opening the main window |

## Privacy and security

Gyrus is designed around a local trust boundary:

- The backend listens only on `127.0.0.1:8080`.
- Browser pages cannot call the local API. Requests with a web Origin are
  rejected before they reach a route.
- Gyrus Saver has a fixed extension identity, pairs with a short-lived backend
  token, and is limited to creating bookmarks. It cannot access backups,
  reset data, read notes, or call AI routes.
- Page fetching and Chromium navigation block redirects and subresources that
  resolve to loopback, private, link-local, or reserved networks. An explicitly
  saved local development URL remains inspectable and is restricted to its
  original host.
- The database, backups, PID, and backend log use owner-only permissions.
- AI runs through a local Ollama server. Gyrus has no hosted model provider.
- Dependency auditing runs in CI, release inputs are pinned, and the standalone
  Python archive is verified by SHA-256 before it is bundled.

Gyrus still accesses the internet when you ask it to fetch a bookmark, load a
live page, refresh metadata, inspect a design, or check links. That traffic goes
directly from your Mac to the referenced website.

## Requirements

- **macOS 26 (Tahoe) or newer**
- Optional: [Ollama](https://ollama.com) for AI Brain, semantic search,
  translation, summaries, and taxonomy review

No Apple Developer membership, Python installation, or external Chromium is
required to run the released app.

## Browser extension

The **Gyrus Saver** companion supports Chromium browsers such as Chrome, Brave,
Arc, and Edge.

### Install from a release

1. Download **`Gyrus-Saver-v1.4.0-beta.1.zip`** from the same GitHub release as the
   DMG and unzip it.
2. Open `chrome://extensions`, `brave://extensions`, or the equivalent page.
3. Enable **Developer mode**.
4. Choose **Load unpacked** and select the unzipped `extension` folder.
5. Pin Gyrus Saver to the toolbar.

When updating from an older development build, remove the old extension first
and then load the new folder. The secured extension has the stable ID
`eoffmpeogpjblmimnhmhddelahenfdpg`.

To verify it, open any normal web page and click Gyrus Saver. The popup confirms
the save, and the bookmark appears in Gyrus under **Inbox**. Gyrus must have
been opened once after a Mac restart so its local backend is running.

The extension requests only `activeTab` and access to `127.0.0.1:8080`. It does
not send data to a Gyrus cloud service because no such service exists.

## AI Brain (optional)

Enable AI under **Settings → AI**, connect Ollama, and choose separate text and
embedding models. Gyrus then gains:

- chat grounded in the selected page rather than model memory alone;
- persistent conversation history per bookmark;
- article, JSON-LD, table, YouTube, site-structure, and design context;
- local summaries, Reader translation, semantic search, and tag-system review;
- an optional Markdown mirror that follows the folder structure and can be
  opened in Obsidian, Logseq, or any editor.

The database remains authoritative. The Markdown mirror is portable output,
not a second hidden database. Clearing the Brain removes only files that Gyrus
can identify as generated; unrelated notes in a selected vault are preserved.

## Architecture

```text
Gyrus.app (SwiftUI + AppKit)
    |
    | supervises a child process over loopback
    v
FastAPI on 127.0.0.1:8080
    |-- routers and Pydantic request boundaries
    |-- services for scraping, design capture, search, AI, and jobs
    |-- SQLAlchemy + Alembic
    `-- SQLite + FTS5 + sqlite-vec

Optional local services:
    Ollama on 127.0.0.1:11434

Browser companion:
    fixed Chrome extension ID -> scoped token -> POST /api/bookmarks only
```

Repository layout:

```text
Gyrus/                  SwiftUI app
  Models/               Codable domain models
  Services/             Stores, API client, settings, backend launcher
  Views/                Sidebar, library, preview, Design, Brain, settings
  Resources/            Assets, Info.plist, localization catalog
GyrusTests/             XCTest suite
backend/                FastAPI backend
  models/ schemas/      database and API models
  routers/ services/    endpoints and application logic
  alembic/ tests/       migrations and pytest suite
extension/              Gyrus Saver Manifest V3 companion
generate_xcodeproj.py   deterministic Xcode-project generator
release.sh              tested build, packaging, checksum, and publish flow
```

## Where data lives

| Data | Location |
|---|---|
| SQLite database, backups, favicons, images, snapshots | `~/.gyrus/` |
| Backend PID, log, and Python bytecode cache | `~/Library/Application Support/Gyrus/` |
| AI Brain Markdown mirror | The `Gyrus Brain` folder selected by the user |
| Application and bundled runtime | `/Applications/Gyrus.app` |

Use Gyrus's export tools before manually deleting these locations.

## Building from source

```sh
git clone https://github.com/gedankenlust/Gyrus.git
cd Gyrus

cd backend
python3 -m venv venv
source venv/bin/activate
pip install -r requirements.txt
cd ..

python3 generate_xcodeproj.py
open Gyrus.xcodeproj
```

Run Gyrus from Xcode with `⌘R`. Development builds use `backend/venv`; release
builds bundle the self-contained runtime produced by:

```sh
cd backend
./build_python_runtime.sh
```

The runtime is generated locally and intentionally ignored by Git.

## Testing

```sh
# Swift app
xcodebuild test -project Gyrus.xcodeproj -scheme Gyrus \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO

# Backend
backend/venv/bin/pytest -q

# Dependency audit
backend/venv/bin/pip-audit -r backend/requirements.txt
```

The release script repeats the regression tests, builds the Release app,
applies an ad-hoc signature with Hardened Runtime on Gyrus, verifies sealed
resources, starts bundled Chromium as a smoke test, creates the DMG and
extension archive, and writes SHA-256 checksums. Build products are written to
`~/Builds/Gyrus/` by default, not into the Git checkout.

## Project status

**Current preview: v1.4.0-beta.1.** Gyrus is an **Early Preview**: it is used as
a real local bookmark and web-research tool and has automated backend and macOS
tests, but workflows and stored-data formats can still change before the next
stable milestone.

The release is ad-hoc signed but not notarized. This keeps distribution possible
without a paid Apple Developer membership, at the cost of the one-time
Gatekeeper confirmation described above.

Preview releases can contain rough edges, especially on websites that block
automation, require a login, or render unusual page structures. Export
important bookmark data before testing a new preview.

## Roadmap

- Multi-bookmark AI questions across a selected set or the full library
- Related-bookmark suggestions backed by local embeddings
- A richer optional knowledge graph for the Markdown mirror
- A signed and notarized build if the project later adopts the Apple Developer
  Program
- A Safari extension if demand justifies the additional native packaging work

## FAQ

**Does Gyrus upload my bookmarks or prompts?**

No. Gyrus has no account system, sync backend, telemetry endpoint, or hosted AI
provider. Website requests and local Ollama requests originate on your Mac.

**Is AI required?**

No. Page, Design, Notes, folders, tags, search, imports, exports, and maintenance
features work without Ollama. The AI Brain tab is hidden while AI is disabled.

**Do I start the backend manually?**

No. Gyrus starts and supervises its bundled backend.

**Why is the app large?**

The release includes Python and a Chromium headless shell so Design inspection
works immediately and consistently on another Mac.

**Which browsers can I import from?**

Anything that exports standard Netscape bookmark HTML, including Brave, Arc,
Chrome, Firefox, and Safari.

**Is Windows or Linux supported?**

No. Gyrus is a native macOS application.

## Contributing

Contributions are welcome. Read [CONTRIBUTING.md](CONTRIBUTING.md) before adding
files because `Gyrus.xcodeproj` is generated by `generate_xcodeproj.py`.

Do not commit local runtimes, build products, databases, DMGs, agent folders,
or editor state. The repository's `.gitignore` covers shared build artifacts;
personal agent and editor folders belong in your global Git ignore or local
`.git/info/exclude`.

## License

[MIT](LICENSE) © Gyrus contributors.

## Acknowledgements

Gyrus is built with [SwiftUI](https://developer.apple.com/swiftui/),
[FastAPI](https://fastapi.tiangolo.com/), [SQLAlchemy](https://www.sqlalchemy.org/),
[Alembic](https://alembic.sqlalchemy.org/), [Playwright](https://playwright.dev/),
and [Ollama](https://ollama.com/). Third-party license information is collected
in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
