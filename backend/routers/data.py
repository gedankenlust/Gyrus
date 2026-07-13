import shutil
from datetime import datetime, timezone
from fastapi import APIRouter, Depends, HTTPException
from fastapi.responses import JSONResponse
from pydantic import BaseModel
from sqlalchemy.orm import Session
from database import get_db, DATA_DIR
from services.brain_sync_service import brain_sync_service
from models.bookmark import Bookmark, BookmarkNote, BrainMessage
from models.collection import Collection
from models.tag import Tag, BookmarkTag

router = APIRouter(prefix="/api/data", tags=["data"])

BACKUP_VERSION = 1


def _iso(dt: datetime | None) -> str | None:
    return dt.isoformat() if dt else None


def _parse_dt(value: str | None) -> datetime:
    if value:
        try:
            return datetime.fromisoformat(value)
        except ValueError:
            pass
    return datetime.now(timezone.utc)

@router.post("/clear-cache")
async def clear_cache():
    """Delete all files in ~/.gyrus/favicons and ~/.gyrus/og-images."""
    favicons_dir = DATA_DIR / "favicons"
    og_images_dir = DATA_DIR / "og_images"
    
    for directory in [favicons_dir, og_images_dir]:
        if directory.exists():
            for item in directory.iterdir():
                if item.is_file():
                    item.unlink()
                elif item.is_dir():
                    shutil.rmtree(item)
    return {"status": "ok"}

@router.post("/clear-brain")
async def clear_brain():
    """Call brain_sync_service.clear_all_files()."""
    brain_sync_service.clear_all_files()
    return {"status": "ok"}

@router.post("/clear-bookmarks")
async def clear_bookmarks(db: Session = Depends(get_db)):
    """Delete all rows from bookmarks, collections, tags, and bookmark_notes."""
    try:
        # Order matters for foreign key constraints if they aren't ON DELETE CASCADE
        # In Gyrus, they seem to be set up well, but we can be explicit.
        db.query(BookmarkTag).delete()
        db.query(BrainMessage).delete()
        db.query(BookmarkNote).delete()
        db.query(Bookmark).delete()
        db.query(Collection).delete()
        db.query(Tag).delete()
        db.commit()
    except Exception as e:
        db.rollback()
        raise HTTPException(status_code=500, detail=str(e))
    return {"status": "ok"}

@router.post("/factory-reset")
async def factory_reset(db: Session = Depends(get_db)):
    """Combine all clear operations."""
    await clear_cache()
    await clear_brain()
    await clear_bookmarks(db)
    return {"status": "ok"}

@router.get("/backup")
def backup(db: Session = Depends(get_db)):
    """Export everything as a portable JSON backup."""
    data = {
        "version": BACKUP_VERSION,
        "exported_at": datetime.now(timezone.utc).isoformat(),
        "collections": [
            {
                "id": c.id, "name": c.name, "icon": c.icon, "color": c.color,
                "parent_id": c.parent_id, "position": c.position,
                "created_at": _iso(c.created_at),
            }
            for c in db.query(Collection).all()
        ],
        "tags": [
            {"id": t.id, "name": t.name, "color": t.color, "created_at": _iso(t.created_at)}
            for t in db.query(Tag).all()
        ],
        "bookmarks": [
            {
                "id": b.id, "title": b.title, "url": b.url,
                "description": b.description, "notes": b.notes,
                "favicon_path": b.favicon_path, "og_image_url": b.og_image_url,
                "og_image_path": b.og_image_path, "source": b.source,
                "is_dead": b.is_dead, "collection_id": b.collection_id,
                "created_at": _iso(b.created_at), "updated_at": _iso(b.updated_at),
            }
            for b in db.query(Bookmark).all()
        ],
        "bookmark_notes": [
            {
                "id": n.id, "bookmark_id": n.bookmark_id, "content": n.content,
                "source": n.source, "created_at": _iso(n.created_at), "updated_at": _iso(n.updated_at),
            }
            for n in db.query(BookmarkNote).all()
        ],
        "brain_messages": [
            {
                "id": m.id, "bookmark_id": m.bookmark_id, "role": m.role,
                "content": m.content, "model": m.model, "status": m.status,
                "created_at": _iso(m.created_at),
            }
            for m in db.query(BrainMessage).all()
        ],
        "bookmark_tags": [
            {
                "bookmark_id": bt.bookmark_id,
                "tag_id": bt.tag_id,
                "source": bt.source,
            }
            for bt in db.query(BookmarkTag).all()
        ],
    }
    return JSONResponse(
        content=data,
        headers={"Content-Disposition": 'attachment; filename="gyrus_backup.json"'},
    )


class RestoreData(BaseModel):
    version: int = BACKUP_VERSION
    collections: list[dict] = []
    tags: list[dict] = []
    bookmarks: list[dict] = []
    bookmark_notes: list[dict] = []
    brain_messages: list[dict] = []
    bookmark_tags: list[dict] = []


@router.post("/restore")
def restore(data: RestoreData, db: Session = Depends(get_db)):
    """Replace ALL current data with the contents of a JSON backup."""
    try:
        # 1. Wipe existing data (FK-safe order).
        db.query(BookmarkTag).delete()
        db.query(BrainMessage).delete()
        db.query(BookmarkNote).delete()
        db.query(Bookmark).delete()
        db.query(Collection).delete()
        db.query(Tag).delete()
        db.flush()

        # 2. Tags.
        for t in data.tags:
            db.add(Tag(id=t["id"], name=t["name"], color=t.get("color"),
                       created_at=_parse_dt(t.get("created_at"))))

        # 3. Collections — two passes so self-referential parent_id never
        #    violates the FK (insert flat, then wire up parents).
        for c in data.collections:
            db.add(Collection(id=c["id"], name=c["name"], icon=c.get("icon"),
                              color=c.get("color"), parent_id=None, position=c.get("position", 0),
                              created_at=_parse_dt(c.get("created_at"))))
        db.flush()
        for c in data.collections:
            if c.get("parent_id"):
                col = db.get(Collection, c["id"])
                if col:
                    col.parent_id = c["parent_id"]
        db.flush()

        # 4. Bookmarks.
        for b in data.bookmarks:
            db.add(Bookmark(
                id=b["id"], title=b.get("title", ""), url=b["url"],
                description=b.get("description"), notes=b.get("notes"),
                favicon_path=b.get("favicon_path"), og_image_url=b.get("og_image_url"),
                og_image_path=b.get("og_image_path"), source=b.get("source", "manual"),
                is_dead=b.get("is_dead", False), collection_id=b.get("collection_id"),
                created_at=_parse_dt(b.get("created_at")), updated_at=_parse_dt(b.get("updated_at")),
            ))
        db.flush()

        # 5. Notes + tag links.
        for n in data.bookmark_notes:
            db.add(BookmarkNote(id=n["id"], bookmark_id=n["bookmark_id"],
                                content=n.get("content", ""), source=n.get("source", "user"),
                                created_at=_parse_dt(n.get("created_at")),
                                updated_at=_parse_dt(n.get("updated_at"))))
        for m in data.brain_messages:
            db.add(BrainMessage(id=m["id"], bookmark_id=m["bookmark_id"],
                                role=m.get("role", "assistant"),
                                content=m.get("content", ""),
                                model=m.get("model"),
                                status=m.get("status", "complete"),
                                created_at=_parse_dt(m.get("created_at"))))
        for bt in data.bookmark_tags:
            db.add(BookmarkTag(
                bookmark_id=bt["bookmark_id"],
                tag_id=bt["tag_id"],
                source=bt.get("source", "manual"),
            ))

        db.commit()
    except Exception as e:
        db.rollback()
        raise HTTPException(status_code=400, detail=f"Restore failed: {e}")

    return {
        "status": "ok",
        "collections": len(data.collections),
        "tags": len(data.tags),
        "bookmarks": len(data.bookmarks),
    }
