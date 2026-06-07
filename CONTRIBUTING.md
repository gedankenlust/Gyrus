# Contributing to Gyrus

Thanks for your interest! Gyrus is a SwiftUI macOS app with a local FastAPI
backend. This guide covers how to build, run and test it, plus the one
project-specific quirk you need to know.

## Prerequisites

- **macOS 26 (Tahoe) or newer**
- **Xcode** (recent version)
- **Python 3**
- *(optional)* **[Ollama](https://ollama.com)** — only for AI Brain work

## Repository layout

```
Gyrus/                  SwiftUI app
  Models/               Codable models (Bookmark, Collection, Tag, …)
  Services/             @Observable stores, APIClient, BackendLauncher, AppSettings
  Views/                Feature-grouped UI (Sidebar, BookmarkList, PreviewPanel, …)
  Resources/            Assets, Info.plist, Localizable.xcstrings
GyrusTests/             XCTest unit tests for the app
backend/                FastAPI backend
  models/ schemas/ services/ routers/   layered architecture
  alembic/              database migrations
  tests/                pytest suite
extension/              "Gyrus Saver" browser extension (MV3)
generate_xcodeproj.py   generates Gyrus.xcodeproj (see below)
```

## ⚠️ The one quirk: the Xcode project is generated

`Gyrus.xcodeproj/project.pbxproj` is **generated** by `generate_xcodeproj.py`.
**Do not hand-edit the project in Xcode's UI** — your changes will be lost on
the next regeneration.

Whenever you **add, remove, or move** a Swift file (in `Gyrus/` or `GyrusTests/`):

```sh
python3 generate_xcodeproj.py
```

The script scans the folders, rebuilds the project, wires the test target, and
writes a shared scheme. It also adds a build phase that bundles the Python
backend into the built `.app` (so a built app runs on any Mac).

## Build & run

```sh
python3 generate_xcodeproj.py   # if you just cloned, or added/removed files
open Gyrus.xcodeproj            # then press Run (⌘R)
```

In development the app reuses the repo's `backend/` and, on first launch, sets up
a local Python virtual environment (installs dependencies, runs migrations) and
offers to set up the optional AI Brain. You do not need to start the backend
yourself.

## Building a distributable app (self-contained)

A release that runs on any Mac **without** a system Python must bundle its own
interpreter. Build it once (and again whenever `requirements.txt` changes):

```sh
cd backend
./build_python_runtime.sh        # downloads a relocatable Python + prod deps
```

This creates `backend/python-runtime/` (gitignored, ~140 MB). The Xcode build
phase bundles it into the `.app`, and `BackendLauncher` runs from it directly —
no venv, no pip, no first-launch bootstrap. Without it, the app falls back to
creating a venv from the system Python (fine for development).

> Not yet wired up: for notarization, the bundled runtime's native libraries
> must be code-signed. Track that with the distribution/signing work.

## Running the tests

**Frontend (Swift):** in Xcode press **⌘U**, or:

```sh
xcodebuild test -project Gyrus.xcodeproj -scheme Gyrus \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
```

**Backend (Python):**

```sh
cd backend
python3 -m venv venv && source venv/bin/activate
pip install -r requirements.txt
pytest
```

Please keep both suites green, and add tests for new behavior.

## Database migrations

Schema changes use **Alembic**. After changing a model in `backend/models/`,
add a migration in `backend/alembic/versions/` (chain it to the current head),
then `alembic upgrade head`. The app also runs `alembic upgrade head` on every
launch, so migrations apply automatically for users.

Note: a `batch_alter_table` on the `bookmarks` table drops the FTS sync
triggers — recreate them afterwards (see the existing migration that documents
this).

## Code style

- **Write code in English** — identifiers and comments. Match the surrounding
  code's naming, comment density and idioms.
- Comments should explain **why**, not restate the code.
- Prefer small, focused changes. Keep the secondary "AI Brain" feature
  best-effort — it must never break core bookmark CRUD.
- Frontend: `@MainActor @Observable` stores, with `AppStore` as a façade.
- Backend: thin routers, logic in `services/`, validation in `schemas/`.

## Pull requests

1. Branch off `main`.
2. Make your change; run both test suites (and `python3 generate_xcodeproj.py`
   if you touched the file set).
3. Describe what changed and why. Screenshots help for UI changes.

## License

By contributing, you agree your contributions are licensed under the project's
[MIT License](LICENSE).
