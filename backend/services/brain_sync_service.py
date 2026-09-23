import os
import hashlib
import tempfile
import re
from pathlib import Path
from typing import Optional
from datetime import datetime
from urllib.parse import quote
from sqlalchemy import select
from sqlalchemy.orm import Session, aliased
from models.bookmark import Bookmark
from models.collection import Collection

import logging
logger = logging.getLogger(__name__)

class BrainSyncService:
    DEFAULT_ROOT = Path.home() / ".gyrus" / "brain"

    def __init__(self, root_dir: Optional[str] = None):
        chosen = root_dir or os.getenv("GYRUS_BRAIN_ROOT") or str(self.DEFAULT_ROOT)
        self.root_dir = Path(chosen).expanduser().resolve()
        self.is_enabled = False
        # The directory is created lazily — on the first write, or when the app
        # pushes an enabled config (update_config). The backend boots with these
        # defaults but the app overrides them on startup, so we must NOT create
        # a folder eagerly: a disabled or differently-located brain would
        # otherwise leave a stray ~/.gyrus/brain behind on every launch.

    def _ensure_root(self):
        """Ensures the root directory exists if enabled."""
        if self.is_enabled:
            self.root_dir.mkdir(parents=True, exist_ok=True)

    def _sanitize_name(self, name: str) -> str:
        """Sanitizes titles and collection names for use in file paths."""
        # Replace illegal characters and dots with underscores
        sanitized = re.sub(r'[\\/*?:"<>|.]', '_', name).strip()
        if not sanitized:
            sanitized = "Untitled"
        # Cap each path component to the filesystem's per-name byte limit
        # (255 on macOS/ext4). A long bookmark title would otherwise make
        # open()/exists() raise ENAMETOOLONG and crash create AND delete.
        # 200 bytes leaves headroom for the ".md" suffix.
        return self._truncate_to_bytes(sanitized, 200)

    @staticmethod
    def _truncate_to_bytes(text: str, max_bytes: int) -> str:
        """Truncate to at most max_bytes of UTF-8, never splitting a character."""
        encoded = text.encode("utf-8")
        if len(encoded) <= max_bytes:
            return text
        return encoded[:max_bytes].decode("utf-8", errors="ignore").rstrip() or "Untitled"

    def _get_collection_path(self, db: Session, collection_id: Optional[str]) -> Path:
        """Resolves the relative directory path for a collection, including parents."""
        # Bookmarks without a collection go to their own folder, kept separate
        # from the real "Inbox" collection so the two don't get mixed on disk.
        if not collection_id:
            return Path("_Unsorted")

        # Use a recursive CTE to fetch all ancestors in a single query (N+1 fix)
        cte = select(Collection.id, Collection.name, Collection.parent_id).where(Collection.id == collection_id).cte(name="parent_chain", recursive=True)
        parent = aliased(Collection)
        cte = cte.union(
            select(parent.id, parent.name, parent.parent_id).join(cte, parent.id == cte.c.parent_id)
        )
        rows = db.execute(select(cte.c.id, cte.c.name, cte.c.parent_id)).all()
        id_to_col = {row.id: row for row in rows}

        path_parts = []
        current_id = collection_id
        visited: set[str] = set()

        # visited-guard: a cyclic parent chain (from old data) would otherwise
        # loop forever. New cycles are already blocked at the API level.
        while current_id and current_id not in visited:
            visited.add(current_id)
            collection = id_to_col.get(current_id)
            if not collection:
                break
            path_parts.insert(0, self._sanitize_name(collection.name))
            current_id = collection.parent_id

        if not path_parts:
            return Path("_Unsorted")

        return Path(*path_parts)

    def _get_bookmark_file_path(self, db: Session, bookmark: Bookmark) -> Path:
        """Returns the full Path to the bookmark's markdown file."""
        rel_dir = self._get_collection_path(db, bookmark.collection_id)
        filename = self.bookmark_filename(bookmark.id, bookmark.title)
        candidate = self.root_dir / rel_dir / filename
        # A legacy or unrelated file is never silently adopted as Gyrus-owned.
        if candidate.exists() and not self._owns(candidate, bookmark.id):
            candidate = candidate.with_name(
                f"{self._sanitize_name(bookmark.title or 'Untitled')}-{bookmark.id}-gyrus.md"
            )
        final_path = candidate.resolve()
        if candidate.is_symlink() or not final_path.is_relative_to(self.root_dir):
            raise ValueError("Brain file must stay inside the selected folder")
        return final_path

    def bookmark_filename(self, bookmark_id: str, title: str) -> str:
        return f"{self._sanitize_name(title or 'Untitled')}-{bookmark_id[:8]}.md"

    @staticmethod
    def _owner(path: Path) -> str | None:
        if path.is_symlink() or not path.is_file():
            return None
        try:
            with path.open(encoding="utf-8") as handle:
                header = handle.read(2048)
            match = re.search(r"^gyrus_bookmark_id: ([A-Za-z0-9_-]{1,128})$", header, re.MULTILINE)
            if match:
                return match[1]
        except (OSError, ValueError):
            pass
        return None

    def _owns(self, path: Path, bookmark_id: str | None = None) -> bool:
        if not path.resolve().is_relative_to(self.root_dir):
            return False
        owner = self._owner(path)
        return owner is not None and (bookmark_id is None or owner == bookmark_id)

    @staticmethod
    def _write_atomic(path: Path, content: str) -> None:
        with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8", dir=path.parent,
                                         prefix=".gyrus-", delete=False) as handle:
            temporary = Path(handle.name)
            try:
                handle.write(content)
                handle.flush()
                os.fsync(handle.fileno())
            except BaseException:
                temporary.unlink(missing_ok=True)
                raise
        try:
            os.replace(temporary, path)
        finally:
            temporary.unlink(missing_ok=True)

    def _related_note_names(self, db: Session, bookmark: Bookmark) -> list[str]:
        """Obsidian note stems for the nearest indexed bookmarks.

        The stem matches the generated filename, so a wikilink connects two
        notes in the vault graph. Missing embeddings produce no links.
        """
        from services.search_service import related_bookmarks

        names = []
        for neighbor in related_bookmarks(db, bookmark.id, limit=5):
            stem = self.bookmark_filename(neighbor.id, neighbor.title or "Untitled")
            if stem.endswith(".md"):
                stem = stem[:-3]
            names.append(stem)
        return names

    def _generated_section(self, bookmark: Bookmark, db: Session | None = None) -> str:
        related = self._related_note_names(db, bookmark) if db is not None else []
        content = self._render_markdown(bookmark, related_notes=related)
        content = content.replace("---\n", f"---\ngyrus_bookmark_id: {bookmark.id}\n", 1)
        digest = hashlib.sha256(content.encode()).hexdigest()
        return content + f"<!-- gyrus:generated-end {digest} -->\n"

    def sync_bookmark(self, db: Session, bookmark: Bookmark, old_path: Optional[Path] = None):
        """Refresh our generated section, preserving appended or edited user text."""
        if not self.is_enabled:
            return
        new_path = self._get_bookmark_file_path(db, bookmark)
        new_path.parent.mkdir(parents=True, exist_ok=True)
        if old_path and old_path != new_path and self._owns(old_path, bookmark.id):
            if new_path.exists():
                raise ValueError("The destination Brain file already exists; both files were preserved")
            old_path.rename(new_path)
            parent = old_path.parent
            while parent != self.root_dir and self.root_dir in parent.parents:
                try:
                    parent.rmdir()
                except OSError:
                    break
                parent = parent.parent

        generated = self._generated_section(bookmark, db)
        if new_path.exists():
            if not self._owns(new_path, bookmark.id):
                raise ValueError("The destination belongs to another note; it was preserved")
            existing = new_path.read_text(encoding="utf-8")
            match = re.search(r"<!-- gyrus:generated-end ([a-f0-9]{64}) -->\n?", existing)
            if not match or hashlib.sha256(existing[:match.start()].encode()).hexdigest() != match[1]:
                # The generated section was edited externally. Preserve that edit.
                return
            generated += existing[match.end():]
            self._write_atomic(new_path, generated)
        else:
            # Exclusive creation also protects a file created concurrently by an editor.
            with new_path.open("x", encoding="utf-8") as handle:
                handle.write(generated)

    @staticmethod
    def _yaml_quote(s: str) -> str:
        s = (s or "").replace("\\", "\\\\").replace('"', '\\"').replace("\n", " ")
        return f'"{s}"'

    def _render_markdown(self, bookmark, related_notes: list[str] | None = None) -> str:
        """Render a bookmark as an Obsidian-friendly Markdown note: frontmatter
        with tags (so the vault indexes them), the description, a link back to
        the original, any AI summary and user notes, and [[wikilinks]] for the
        tags so a knowledge graph forms. Scraped page content and chat history
        are appended later on demand by the brain/chat code, not here."""
        tags = [bt.tag.name for bt in bookmark.bookmark_tags]
        created = bookmark.created_at.strftime("%Y-%m-%d") if bookmark.created_at else ""

        lines = [
            "---",
            f"title: {self._yaml_quote(bookmark.title or 'Untitled')}",
            f"url: {bookmark.url}",
            f"created: {created}",
            f"tags: [{', '.join(self._yaml_quote(t) for t in tags)}]",
            "---",
            "",
            f"# {bookmark.title or 'Untitled'}",
            "",
        ]
        if bookmark.description:
            lines += [bookmark.description.strip(), ""]
        lines += [f"[Open original]({bookmark.url})", ""]

        ai_notes = [n.content.strip() for n in bookmark.bookmark_notes
                    if n.source == "ai" and n.content]
        if ai_notes:
            lines += ["## Summary", ""] + [c for note in ai_notes for c in (note, "")]

        user_notes = [n.content.strip() for n in bookmark.bookmark_notes
                      if n.source != "ai" and n.content]
        note_field = bookmark.notes.strip() if bookmark.notes else ""
        if note_field or user_notes:
            lines += ["## Notes", ""]
            if note_field:
                lines += [note_field, ""]
            lines += [c for note in user_notes for c in (note, "")]

        if tags:
            lines += ["Tags: " + " ".join(f"[[{t}]]" for t in tags), ""]

        related = [name.strip() for name in (related_notes or []) if name and name.strip()]
        if related:
            lines += ["## Related", ""]
            lines += [f"[[{name}]]" for name in related]
            lines += [""]

        return "\n".join(lines).rstrip() + "\n"

    def update_config(self, new_root: Optional[str], is_enabled: bool):
        """Applies the brain location and on/off state pushed from the app.

        new_root may be None when the user hasn't chosen a folder — fall back
        to the default location rather than failing. The directory is only
        created when the brain is actually enabled.
        """
        chosen = new_root or os.getenv("GYRUS_BRAIN_ROOT") or str(self.DEFAULT_ROOT)
        self.root_dir = Path(chosen).expanduser().resolve()
        self.is_enabled = is_enabled
        if is_enabled:
            self._ensure_root()

    def append_interaction(self, db: Session, bookmark: Bookmark, prompt: str, response: str):
        """Appends a chat interaction to the bookmark's markdown file."""
        if not self.is_enabled:
            return

        path = self._get_bookmark_file_path(db, bookmark)
        self.sync_bookmark(db, bookmark)
        if not self._owns(path, bookmark.id):
            return

        interaction = f"\n\n## Chat Interaction ({datetime.now()})\n**You:** {prompt}\n\n**AI:** {response}\n"

        with open(path, "a", encoding="utf-8") as f:
            f.write(interaction)

    def clear_chat_interactions(self, db: Session, bookmark: Bookmark):
        """Remove persisted chat transcript blocks from the markdown mirror.

        The database is the authoritative chat store; this keeps the optional
        Markdown mirror consistent when the user clears a conversation in the UI.
        """
        if not self.is_enabled:
            return
        path = self._get_bookmark_file_path(db, bookmark)
        if not self._owns(path, bookmark.id):
            return
        try:
            text = path.read_text(encoding="utf-8")
            cleaned = re.sub(
                r"\n{2,}## Chat Interaction \([^\n]*\)\n.*?(?=\n{2,}## Chat Interaction \(|\Z)",
                "",
                text,
                flags=re.DOTALL,
            ).rstrip() + "\n"
            path.write_text(cleaned, encoding="utf-8")
        except Exception as e:
            logger.warning("Failed to clear markdown chat interactions: %s", e)

    def delete_bookmark_file(self, db: Session, bookmark: Bookmark):
        """Removes the bookmark file from disk."""
        path = self._get_bookmark_file_path(db, bookmark)
        if self._owns(path, bookmark.id):
            path.unlink()

    def delete_bookmarks_files(self, db: Session, bookmarks: list[Bookmark]):
        """Remove only identified Gyrus files for the given bookmarks."""
        for bookmark in bookmarks:
            self.delete_bookmark_file(db, bookmark)

    def clear_all_files(self):
        """Delete only files that can be identified as Gyrus-generated.

        Users may point the Brain at an existing Obsidian vault. A reset must
        never treat that whole folder as disposable user data.
        """
        if not self.root_dir.exists():
            return
        root = self.root_dir.resolve()
        home = Path.home().resolve()
        protected = {
            Path("/").resolve(),
            home,
            *(home / name for name in ("Desktop", "Documents", "Downloads", "Library")),
        }
        if root in protected or len(root.parts) < 3:
            raise ValueError(f"Refusing to clear unsafe Brain root: {root}")
            
        for item in root.rglob("*.md"):
            if self._owns(item) or self._owns_index(item):
                item.unlink()
        # Do not prune unrelated empty folders in a user's existing vault.

    def _owns_index(self, path: Path) -> bool:
        if path.is_symlink() or not path.is_file() or not path.resolve().is_relative_to(self.root_dir):
            return False
        try:
            return path.read_text(encoding="utf-8").startswith("<!-- gyrus:index v1 -->\n")
        except OSError:
            return False

    def index_path(self) -> Path:
        for name in [self.INDEX_FILENAME, "_Gyrus-Index.md"] + [f"_Gyrus-Index-{n}.md" for n in range(1, 1000)]:
            path = self.root_dir / name
            if path.is_symlink() or not path.resolve().is_relative_to(self.root_dir):
                continue
            if not path.exists() or self._owns_index(path):
                return path
        raise ValueError("No unused destination for the Brain index")

    def resync_all(self, db: Session) -> None:
        """Move identified Gyrus files and refresh generated metadata.

        Legacy files without an ownership marker are preserved in place.
        """
        if not self.is_enabled or not self.root_dir.exists():
            return

        bookmarks = db.query(Bookmark).filter(Bookmark.deleted_at.is_(None)).all()
        owned = {self._owner(path): path for path in self.root_dir.rglob("*.md") if self._owns(path)}
        for bookmark in bookmarks:
            try:
                self.sync_bookmark(db, bookmark, old_path=owned.get(bookmark.id))
            except (OSError, ValueError) as exc:
                logger.warning("Could not sync Brain bookmark %s: %s", bookmark.id, exc)
        self.rebuild_index(db, force=True)

    INDEX_FILENAME = "_Index.md"

    def rebuild_index(self, db: Session, force: bool = False) -> None:
        """Write a single auto-generated `_Index.md` at the brain root listing
        ALL bookmarks (from the database, so it's always complete — even those
        without a chat file yet), grouped by folder, with links and tags.

        Rebuild after each completed mutation. Skipping a last write in a
        debounce window left links stale indefinitely after a rename. Bulk
        operations call this once after committing their whole batch."""
        if not self.is_enabled:
            return
        try:
            self.root_dir.mkdir(parents=True, exist_ok=True)
        except Exception:
            return

        from models.tag import Tag, BookmarkTag

        # Build collection paths ONCE from an in-memory map (no per-bookmark
        # query — that was O(bookmarks × DB hits) and timed out at 100k).
        cols = {c.id: c for c in db.query(Collection).all()}
        path_cache: dict[str, str] = {}

        def col_path(cid: Optional[str]) -> str:
            if not cid:
                return "_Unsorted"
            if cid in path_cache:
                return path_cache[cid]
            parts, cur, seen = [], cid, set()
            while cur and cur not in seen and cur in cols:
                seen.add(cur)
                c = cols[cur]
                parts.insert(0, self._sanitize_name(c.name))
                cur = c.parent_id
            result = "/".join(parts) if parts else "_Unsorted"
            path_cache[cid] = result
            return result

        # Bulk-load tags grouped by bookmark (avoids a lazy query per bookmark).
        tags_by_bm: dict[str, list[str]] = {}
        for bid, tname in (db.query(BookmarkTag.bookmark_id, Tag.name)
                           .join(Tag, Tag.id == BookmarkTag.tag_id).all()):
            tags_by_bm.setdefault(bid, []).append(tname)

        # Only the columns we need — no full ORM objects, no lazy relations.
        rows = db.query(Bookmark.id, Bookmark.title, Bookmark.url, Bookmark.collection_id).filter(Bookmark.deleted_at.is_(None)).all()

        groups: dict[str, list] = {}
        for bid, title, url, cid in rows:
            groups.setdefault(col_path(cid), []).append((bid, title or "Untitled", url))

        lines = [
            "<!-- gyrus:index v1 -->",
            "# Gyrus Index",
            "",
            f"_Auto-generated · {len(rows)} bookmarks · {datetime.now():%Y-%m-%d %H:%M}_",
            "",
            "> This file is rewritten by Gyrus. Manual edits will be overwritten.",
            "",
        ]
        for rel_dir in sorted(groups, key=lambda s: (s == "_Unsorted", s.lower())):
            items = groups[rel_dir]
            display = "Unsorted" if rel_dir == "_Unsorted" else rel_dir.replace("/", " / ")
            lines.append(f"## {display} ({len(items)})")
            for bid, title, url in sorted(items, key=lambda x: x[1].lower()):
                safe_title = title.replace("[", "(").replace("]", ")")
                filename = self.bookmark_filename(bid, title)
                candidate = self.root_dir / rel_dir / filename
                if candidate.exists() and not self._owns(candidate, bid):
                    filename = f"{self._sanitize_name(title)}-{bid}-gyrus.md"
                rel_md = quote(f"{rel_dir}/{filename}")
                entry = f"- [{safe_title}]({rel_md}) — {url}"
                tags = tags_by_bm.get(bid)
                if tags:
                    entry += " " + " ".join("#" + t.replace(" ", "_") for t in tags)
                lines.append(entry)
            lines.append("")

        content = "\n".join(lines).rstrip() + "\n"
        try:
            path = self.index_path()
            if path.exists() and not self._owns_index(path):
                raise ValueError("The Brain index destination belongs to another note")
            if path.exists():
                self._write_atomic(path, content)
            else:
                with path.open("x", encoding="utf-8") as handle:
                    handle.write(content)
        except Exception as e:
            logger.warning(f"Failed to write brain index: {e}")

# Global instance
brain_sync_service = BrainSyncService()
