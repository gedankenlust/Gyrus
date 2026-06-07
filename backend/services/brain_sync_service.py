import os
import re
import shutil
import time
from pathlib import Path
from typing import Optional
from datetime import datetime
from urllib.parse import quote
from sqlalchemy.orm import Session
from models.bookmark import Bookmark
from models.collection import Collection

class BrainSyncService:
    DEFAULT_ROOT = Path.home() / ".gyrus" / "brain"

    def __init__(self, root_dir: Optional[str] = None):
        chosen = root_dir or os.getenv("GYRUS_BRAIN_ROOT") or str(self.DEFAULT_ROOT)
        self.root_dir = Path(chosen).expanduser().resolve()
        self.is_enabled = True
        self._last_index_rebuild = 0.0
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

        path_parts = []
        current_id = collection_id
        visited: set[str] = set()

        # visited-guard: a cyclic parent chain (from old data) would otherwise
        # loop forever. New cycles are already blocked at the API level.
        while current_id and current_id not in visited:
            visited.add(current_id)
            collection = db.query(Collection).filter(Collection.id == current_id).first()
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
        filename = f"{self._sanitize_name(bookmark.title or 'Untitled')}.md"
        final_path = (self.root_dir / rel_dir / filename).resolve()
        
        # Security Check: Ensure path traversal didn't escape root
        if not final_path.is_relative_to(self.root_dir):
            raise ValueError(f"Security error: Target path escapes root directory! {final_path}")
            
        return final_path

    def sync_bookmark(self, db: Session, bookmark: Bookmark, old_path: Optional[Path] = None):
        """Creates or moves the bookmark markdown file."""
        if not self.is_enabled:
            return

        new_path = self._get_bookmark_file_path(db, bookmark)

        # Handle move/rename
        if old_path and old_path.exists() and old_path != new_path:
            # Ensure new directory exists
            new_path.parent.mkdir(parents=True, exist_ok=True)
            old_path.rename(new_path)

        # If the file already exists, don't overwrite it to avoid data loss (e.g. chat history)
        if new_path.exists():
            return

        # Ensure directory exists for new file
        new_path.parent.mkdir(parents=True, exist_ok=True)

        # Write content (simple frontmatter for now)
        content = f"""---
title: {bookmark.title}
url: {bookmark.url}
created_at: {bookmark.created_at}
---

# {bookmark.title}

{bookmark.description or ""}
"""
        with open(new_path, "w", encoding="utf-8") as f:
            f.write(content)

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
        if not path.exists():
            self.sync_bookmark(db, bookmark)

        interaction = f"\n\n## Chat Interaction ({datetime.now()})\n**You:** {prompt}\n\n**AI:** {response}\n"

        with open(path, "a", encoding="utf-8") as f:
            f.write(interaction)

    def delete_bookmark_file(self, db: Session, bookmark: Bookmark):
        """Removes the bookmark file from disk."""
        path = self._get_bookmark_file_path(db, bookmark)
        if path.exists():
            path.unlink()

    def clear_all_files(self):
        """Deletes all files and directories inside the root directory."""
        if not self.root_dir.exists():
            return
            
        for item in self.root_dir.iterdir():
            if item.is_file():
                item.unlink()
            elif item.is_dir():
                shutil.rmtree(item)

    @staticmethod
    def _frontmatter_url(path: Path) -> Optional[str]:
        """Read the `url:` field from a markdown file's frontmatter."""
        try:
            with open(path, "r", encoding="utf-8") as f:
                for _ in range(15):
                    line = f.readline()
                    if not line:
                        break
                    if line.startswith("url:"):
                        return line[len("url:"):].strip()
        except Exception:
            return None
        return None

    def _prune_empty_dirs(self) -> None:
        """Remove empty leftover directories (deepest first), keeping the root."""
        dirs = [p for p in self.root_dir.rglob("*") if p.is_dir()]
        for d in sorted(dirs, key=lambda p: len(p.parts), reverse=True):
            try:
                if not any(d.iterdir()):
                    d.rmdir()
            except Exception:
                pass

    def resync_all(self, db: Session) -> None:
        """Reconcile the on-disk structure with the database: move every
        existing markdown file to the folder its bookmark now belongs to
        (matched by URL, which is stable across renames), then drop empty
        directories. This is what keeps the brain mirroring Gyrus after folder
        renames, moves and deletes."""
        if not self.is_enabled or not self.root_dir.exists():
            return

        by_url = {bm.url: bm for bm in db.query(Bookmark).all()}
        for path in [p for p in self.root_dir.rglob("*.md") if p.is_file()]:
            url = self._frontmatter_url(path)
            if not url:
                continue
            bookmark = by_url.get(url)
            if bookmark is None:
                continue
            correct = self._get_bookmark_file_path(db, bookmark)
            if correct == path:
                continue
            try:
                correct.parent.mkdir(parents=True, exist_ok=True)
                if correct.exists():
                    continue  # don't clobber a file already at the target
                path.rename(correct)
            except Exception:
                pass

        self._prune_empty_dirs()
        self.rebuild_index(db, force=True)

    INDEX_FILENAME = "_Index.md"

    def rebuild_index(self, db: Session, force: bool = False) -> None:
        """Write a single auto-generated `_Index.md` at the brain root listing
        ALL bookmarks (from the database, so it's always complete — even those
        without a chat file yet), grouped by folder, with links and tags.

        Debounced: rapid successive mutations skip the (potentially heavy)
        rebuild; the next call after the window catches everything up. Pass
        force=True for the startup/folder reconcile."""
        if not self.is_enabled:
            return
        now = time.monotonic()
        if not force and (now - self._last_index_rebuild) < 3.0:
            return
        self._last_index_rebuild = now
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
        rows = db.query(Bookmark.id, Bookmark.title, Bookmark.url, Bookmark.collection_id).all()

        groups: dict[str, list] = {}
        for bid, title, url, cid in rows:
            groups.setdefault(col_path(cid), []).append((bid, title or "Untitled", url))

        lines = [
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
                rel_md = quote(f"{rel_dir}/{self._sanitize_name(title)}.md")
                entry = f"- [{safe_title}]({rel_md}) — {url}"
                tags = tags_by_bm.get(bid)
                if tags:
                    entry += " " + " ".join("#" + t.replace(" ", "_") for t in tags)
                lines.append(entry)
            lines.append("")

        content = "\n".join(lines).rstrip() + "\n"
        try:
            (self.root_dir / self.INDEX_FILENAME).write_text(content, encoding="utf-8")
        except Exception as e:
            print(f"Failed to write brain index: {e}")

# Global instance
brain_sync_service = BrainSyncService()
