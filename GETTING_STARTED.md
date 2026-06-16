# Getting Started with Gyrus

*Scroll down for the German version — Deutsche Version weiter unten ⬇️*

---

## 🇬🇧 English

Gyrus is a local-first bookmark manager for macOS. Everything runs and stays on
your own Mac — no account, no cloud, no telemetry.

### 1. Requirements

- **macOS 26 (Tahoe)** or newer
- **Xcode** (to build the app)
- **Python 3** (the backend uses it — already on most Macs)
- *(optional)* **[Ollama](https://ollama.com)** — only if you want the AI Brain

### 2. Install & run

```sh
# Clone the project, then open it in Xcode
open Gyrus.xcodeproj
```

In Xcode, press **Run (⌘R)**. That's it — you do **not** need to start the
backend yourself:

- On the **first launch**, the app sets up its Python backend automatically
  (creates a virtual environment, installs dependencies, runs the database
  migrations). This can take a minute — you'll see "Installing dependencies…".
- After that, the backend starts in the background every time you open the app,
  and shuts down when you quit.

> If you prefer to set the backend up by hand first, run `cd backend && ./setup.sh`.

### 3. First launch

When the app opens the first time, you'll see a one-time **AI Brain** dialog:

- **Not now** — skips the AI feature. You can enable it later in Settings.
- **Enable AI Brain** — turns it on and lets you choose where its Markdown
  files are stored (a `Gyrus Brain` subfolder is created inside the folder you
  pick).

Then you land in the main window with an empty bookmark list.

### 4. Adding bookmarks

There are three ways to get bookmarks into Gyrus:

- **Add a single bookmark** manually from the toolbar.
- **Browser extension** (see section 7) — saves the page you're on with one click.
- **Import from your browser** — see below.

#### Importing

1. **Export from your browser first.** Every browser can save its bookmarks as
   an HTML file (the "Netscape" format):
   - *Chrome / Brave / Edge*: Bookmarks → Bookmark Manager → ⋮ → **Export bookmarks**
   - *Firefox*: Bookmarks → Manage Bookmarks → Import and Backup → **Export Bookmarks to HTML**
   - *Safari*: File → **Export Bookmarks…**
2. In Gyrus, choose **File → Import Bookmarks…** (⌘I).
3. **Drag & drop** the `.html` file onto the window, or click **Choose File…**.
4. *(Optional)* Type a name into **"Import into folder"** (e.g. `Brave`). This
   wraps the whole import inside one top-level folder — handy for keeping
   different browsers apart.
5. Gyrus shows how many bookmarks were **imported**, **skipped** and how many
   **folders** it created.

Good to know:

- The **folder structure** of your export is preserved.
- **Duplicates are skipped** — re-importing the same file won't create copies.
- Re-importing **merges into existing folders** by name instead of duplicating
  the whole tree, so you can safely import again after adding new bookmarks.

#### Exporting

- **Export everything**: click the **share / export button** in the sidebar.
- **Export a single folder**: **right-click a folder → "Export Folder…"**.

Then pick a format and choose where to save the file:

| Format | Best for |
|--------|----------|
| **HTML** | Re-importing into any browser (or back into Gyrus) |
| **CSV** | Spreadsheets — Excel, Numbers, Google Sheets |
| **Markdown** | A readable list grouped by folder, with title + URL |
| **Plain Text** | One URL per line — compact and simple |

The format that's pre-selected comes from **Settings → Appearance** ("Default
export format").

### 5. Organizing & finding

- **Folders & tags**: create, rename, recolor and delete folders in the
  sidebar; drag bookmarks between folders; right-click for bulk tagging.
- **Search**: type in the search bar (or press **⌘K** for the command palette)
  to search titles, URLs, notes **and tags**.
- **Select many**: drag a rubber-band box over cards, Shift- or ⌘-click, or use
  "Select all" — then drag the selection into a folder, or tag/delete them at
  once.
- **Preview**: select a bookmark to see a live web preview or its Open Graph
  metadata in the right panel.
- **Dead-link check**: runs in the background and flags 404s so you can clean
  them up.
- **Refresh metadata**: in **Settings → Data**, "Refresh All Metadata"
  re-fetches favicons, descriptions and preview images for every bookmark.
- **Notes**: each bookmark has a Markdown notes field that auto-saves.

#### ⌨️ Global Search (Spotlight-style)

You can call Gyrus from anywhere in macOS using a system-wide hotkey.
- **Default shortcut**: `⌥ Space` (Option-Space)
- This activates the app and opens the **Command Palette** (search bar) instantly.
- You can customize this shortcut in **Settings → General → Behavior**.

#### 🪄 AI Auto-Tags (Magic Tagging)

Let Gyrus categorize your links for you.
1. Enter **Edit Mode** for a bookmark (click the pencil icon).
2. Click the **magic wand icon** (🪄) next to the tags field.
3. Gyrus will analyze the page content using your local AI and suggest the most
   relevant tags.

#### 📖 Reader Mode

Read articles without the clutter.
1. Select a bookmark.
2. Click the **Reader** tab in the right-hand panel.
3. Gyrus extracts the article text and displays it in a clean, distraction-free
   Markdown view.


### 6. AI Brain (optional)

The AI Brain reads the page (article text, structured data, tables, YouTube) and
lets you chat about it using a **local** language model — nothing is sent to the
cloud. Each bookmark mirrors to a Markdown file whose folder matches your Gyrus
structure.

To use it:

1. Install **[Ollama](https://ollama.com)** and pull a model, e.g.:
   ```sh
   ollama pull llama3
   ```
2. In Gyrus, open **Settings → AI Brain**, enable it, and make sure the Ollama
   URL (`http://localhost:11434` by default) shows a green "connected" dot.
3. Pick the model from the dropdown.
4. Open a bookmark's **AI Brain** tab and ask away.

Your brain files live in the folder you chose during onboarding (or
`~/.gyrus/brain` by default).

### 7. Browser extension ("Gyrus Saver")

A small popup that saves the current tab into your **Inbox**.

1. Open `chrome://extensions` (Chrome / Brave / Edge).
2. Turn on **Developer mode** (top-right).
3. Click **Load unpacked** and select the `extension/` folder of this project.
4. Click the extension icon to save the current tab. Gyrus's local backend
   keeps running in the background, so this works even with the Gyrus window
   closed — you don't need it in the foreground. (Just open Gyrus once after a
   reboot so the backend is up.)

### 8. Where your data lives (privacy)

Everything is stored under `~/.gyrus/` on your Mac:

- `db/gyrus.db` — your bookmarks (SQLite)
- `db/backups/` — automatic daily snapshots
- `favicons/`, `og_images/` — cached preview images

Your AI Brain Markdown files live wherever you chose. None of this leaves your
machine, and none of it is part of the app's source code.

### 9. Troubleshooting

- **"Backend did not respond"** — quit the app fully (⌘Q) and reopen. On a very
  first launch, give it a minute to install dependencies.
- **AI models not showing** — make sure Ollama is running (`ollama serve`) and
  that you pulled at least one model.
- **Start completely fresh** (wipe all local data and settings):
  ```sh
  rm -rf ~/.gyrus                 # deletes bookmarks + brain — back up first if needed
  defaults delete com.gyrus.app   # resets app settings, re-shows onboarding
  ```

---
---

## 🇩🇪 Deutsch

Gyrus ist ein „local-first" Lesezeichen-Manager für macOS. Alles läuft und
bleibt auf deinem eigenen Mac — kein Konto, keine Cloud, keine Telemetrie.

### 1. Voraussetzungen

- **macOS 26 (Tahoe)** oder neuer
- **Xcode** (zum Bauen der App)
- **Python 3** (für das Backend — auf den meisten Macs schon vorhanden)
- *(optional)* **[Ollama](https://ollama.com)** — nur falls du das AI Brain nutzen willst

### 2. Installieren & starten

```sh
# Projekt holen, dann in Xcode öffnen
open Gyrus.xcodeproj
```

In Xcode auf **Ausführen (⌘R)** drücken. Mehr ist nicht nötig — du musst das
Backend **nicht** selbst starten:

- Beim **ersten Start** richtet die App ihr Python-Backend automatisch ein
  (erstellt eine virtuelle Umgebung, installiert Abhängigkeiten, führt die
  Datenbank-Migrationen aus). Das kann eine Minute dauern — du siehst
  „Installing dependencies…".
- Danach startet das Backend bei jedem Öffnen im Hintergrund und stoppt beim
  Beenden der App.

> Wenn du das Backend lieber vorab von Hand einrichtest: `cd backend && ./setup.sh`.

### 3. Erster Start

Beim ersten Öffnen erscheint einmalig der **AI-Brain-Dialog**:

- **Not now** — überspringt die KI-Funktion. Du kannst sie später in den
  Einstellungen aktivieren.
- **Enable AI Brain** — schaltet sie ein und lässt dich wählen, wo die
  Markdown-Dateien gespeichert werden (im gewählten Ordner wird automatisch ein
  Unterordner `Gyrus Brain` angelegt).

Danach landest du im Hauptfenster mit leerer Lesezeichen-Liste.

### 4. Lesezeichen hinzufügen

Es gibt drei Wege, Lesezeichen in Gyrus zu bekommen:

- **Einzelnes Lesezeichen** manuell über die Symbolleiste anlegen.
- **Browser-Extension** (siehe Punkt 7) — speichert die aktuelle Seite mit einem Klick.
- **Aus dem Browser importieren** — siehe unten.

#### Importieren

1. **Zuerst im Browser exportieren.** Jeder Browser kann seine Lesezeichen als
   HTML-Datei speichern (das „Netscape"-Format):
   - *Chrome / Brave / Edge*: Lesezeichen → Lesezeichen-Manager → ⋮ → **Lesezeichen exportieren**
   - *Firefox*: Lesezeichen → Lesezeichen verwalten → Importieren und Sichern → **Lesezeichen nach HTML exportieren**
   - *Safari*: Ablage → **Lesezeichen exportieren…**
2. In Gyrus **File → Import Bookmarks…** (⌘I) wählen.
3. Die `.html`-Datei per **Drag & Drop** aufs Fenster ziehen oder auf
   **„Choose File…"** klicken.
4. *(Optional)* Bei **„Import into folder"** einen Namen eingeben (z. B. `Brave`).
   Damit wird der ganze Import in **einen obersten Ordner** gepackt — praktisch,
   um verschiedene Browser auseinanderzuhalten.
5. Gyrus zeigt danach, wie viele Lesezeichen **importiert**, **übersprungen** und
   wie viele **Ordner** angelegt wurden.

Gut zu wissen:

- Die **Ordnerstruktur** deines Exports bleibt erhalten.
- **Duplikate werden übersprungen** — dieselbe Datei erneut zu importieren legt
  keine Kopien an.
- Ein erneuter Import **fügt in bestehende Ordner ein** (nach Name), statt den
  ganzen Baum zu verdoppeln — du kannst also gefahrlos nachimportieren.

#### Exportieren

- **Alles exportieren**: auf den **Teilen-/Export-Knopf** in der Seitenleiste klicken.
- **Einzelnen Ordner exportieren**: **Rechtsklick auf einen Ordner → „Export Folder…"**.

Dann ein Format wählen und den Speicherort festlegen:

| Format | Am besten für |
|--------|---------------|
| **HTML** | Re-Import in jeden Browser (oder zurück in Gyrus) |
| **CSV** | Tabellen — Excel, Numbers, Google Sheets |
| **Markdown** | Lesbare Liste, nach Ordnern gruppiert, mit Titel + URL |
| **Plain Text** | Eine URL pro Zeile — kompakt und einfach |

Das vorausgewählte Format kommt aus **Einstellungen → Appearance** („Default
export format").

### 5. Ordnen & finden

- **Ordner & Tags**: in der Seitenleiste anlegen, umbenennen, einfärben,
  löschen; Lesezeichen per Drag & Drop zwischen Ordnern verschieben; per
  Rechtsklick mehrere auf einmal taggen.
- **Suche**: ins Suchfeld tippen (oder **⌘K** für die Befehlspalette) — durchsucht
  Titel, URLs, Notizen **und Tags**.
- **Mehrfachauswahl**: Rechteck über die Karten aufziehen, Shift- oder ⌘-Klick,
  oder „Alle auswählen" — dann die Auswahl in einen Ordner ziehen oder auf
  einmal taggen/löschen.
- **Vorschau**: Lesezeichen auswählen → rechts eine Live-Webvorschau oder die
  Open-Graph-Metadaten.
- **Tote-Links-Prüfung**: läuft im Hintergrund und markiert 404er zum Aufräumen.
- **Metadaten aktualisieren**: unter **Einstellungen → Daten** holt „Refresh All
  Metadata" Favicons, Beschreibungen und Vorschaubilder für alle Lesezeichen neu.
- **Notizen**: jedes Lesezeichen hat ein Markdown-Notizfeld mit Auto-Speichern.

#### ⌨️ Globale Suche (Spotlight-Style)

Du kannst Gyrus von überall in macOS über einen systemweiten Shortcut aufrufen.
- **Standard-Shortcut**: `⌥ Leertaste` (Option-Space)
- Dies aktiviert die App und öffnet sofort die **Befehlspalette** (Suche).
- Du kannst diesen Shortcut in den **Einstellungen → General → Behavior** anpassen.

#### 🪄 KI-Auto-Tags (Magic Tagging)

Lass Gyrus deine Links automatisch kategorisieren.
1. Gehe in den **Bearbeiten-Modus** eines Lesezeichens (Klick auf das Stift-Icon).
2. Klicke auf das **Zauberstab-Symbol** (🪄) neben dem Tag-Feld.
3. Gyrus analysiert den Seiteninhalt mit deiner lokalen KI und schlägt die
   passendsten Tags vor.

#### 📖 Reader-Modus

Artikel ohne Ablenkung lesen.
1. Wähle ein Lesezeichen aus.
2. Klicke auf den Reiter **Reader** im rechten Panel.
3. Gyrus extrahiert den Text und zeigt ihn in einer sauberen Markdown-Ansicht an.


### 6. AI Brain (optional)

Das AI Brain liest die Seite (Artikeltext, strukturierte Daten, Tabellen,
YouTube) und lässt dich darüber mit einem **lokalen** Sprachmodell chatten —
nichts geht in die Cloud. Jedes Lesezeichen wird als Markdown-Datei gespiegelt,
deren Ordner deiner Gyrus-Struktur folgt.

So nutzt du es:

1. **[Ollama](https://ollama.com)** installieren und ein Modell laden, z. B.:
   ```sh
   ollama pull llama3
   ```
2. In Gyrus **Einstellungen → AI Brain** öffnen, aktivieren und prüfen, dass die
   Ollama-URL (`http://localhost:11434` als Standard) einen grünen
   „Verbunden"-Punkt zeigt.
3. Modell aus der Liste wählen.
4. Beim Lesezeichen den **AI-Brain**-Tab öffnen und losfragen.

Deine Brain-Dateien liegen im beim Onboarding gewählten Ordner (oder standardmäßig
`~/.gyrus/brain`).

### 7. Browser-Extension („Gyrus Saver")

Ein kleines Popup, das die aktuelle Seite in deine **Inbox** speichert.

1. `chrome://extensions` öffnen (Chrome / Brave / Edge).
2. **Entwicklermodus** oben rechts einschalten.
3. **Entpackt laden** klicken und den Ordner `extension/` dieses Projekts wählen.
4. Auf das Extension-Symbol klicken, um die aktuelle Seite zu speichern. Das
   lokale Gyrus-Backend läuft im Hintergrund weiter — das funktioniert also
   auch bei geschlossenem Gyrus-Fenster, du musst Gyrus nicht im Vordergrund
   haben. (Öffne Gyrus nach einem Neustart einmal, damit das Backend läuft.)

### 8. Wo deine Daten liegen (Datenschutz)

Alles wird unter `~/.gyrus/` auf deinem Mac gespeichert:

- `db/gyrus.db` — deine Lesezeichen (SQLite)
- `db/backups/` — automatische tägliche Sicherungen
- `favicons/`, `og_images/` — zwischengespeicherte Vorschaubilder

Deine AI-Brain-Markdown-Dateien liegen dort, wo du es gewählt hast. Nichts davon
verlässt deinen Rechner, und nichts davon ist Teil des Quellcodes.

### 9. Problembehebung

- **„Backend did not respond"** — App komplett beenden (⌘Q) und neu öffnen. Beim
  allerersten Start eine Minute Zeit geben (Abhängigkeiten werden installiert).
- **Keine KI-Modelle sichtbar** — sicherstellen, dass Ollama läuft
  (`ollama serve`) und mindestens ein Modell geladen ist.
- **Komplett von vorn beginnen** (alle lokalen Daten & Einstellungen löschen):
  ```sh
  rm -rf ~/.gyrus                 # löscht Lesezeichen + Brain — vorher sichern, falls nötig
  defaults delete com.gyrus.app   # setzt App-Einstellungen zurück, zeigt Onboarding erneut
  ```
