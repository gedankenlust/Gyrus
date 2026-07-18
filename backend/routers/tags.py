import logging

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel
from sqlalchemy import func
from sqlalchemy.orm import Session
from database import get_db
from models.tag import Tag, BookmarkTag
from models.bookmark import Bookmark
from schemas.bookmark import BookmarkOut
from schemas.tag import TagCreate, TagUpdate, TagOut
from services.brain_sync_service import brain_sync_service
from services.tag_colors import next_color, rebalanced

router = APIRouter(prefix="/api/tags", tags=["tags"])
logger = logging.getLogger(__name__)


class TagRestore(BaseModel):
    name: str
    color: str | None = None
    bookmark_ids: list[str] = []


class TagMerge(BaseModel):
    source_ids: list[str]
    target_id: str


class BulkTagAssignment(BaseModel):
    bookmark_ids: list[str]
    add_tag_ids: list[str] = []
    remove_tag_ids: list[str] = []


def _tags_out(db: Session) -> list[TagOut]:
    tags = db.query(Tag).order_by(Tag.name).all()

    # Count non-trashed bookmarks per tag (mirrors how folders are counted).
    rows = (
        db.query(BookmarkTag.tag_id, func.count(BookmarkTag.bookmark_id))
        .join(Bookmark, Bookmark.id == BookmarkTag.bookmark_id)
        .filter(Bookmark.deleted_at.is_(None))
        .group_by(BookmarkTag.tag_id)
        .all()
    )
    counts = {tid: cnt for tid, cnt in rows}

    out = []
    for t in tags:
        item = TagOut.model_validate(t)
        item.bookmark_count = counts.get(t.id, 0)
        out.append(item)
    return out


@router.get("", response_model=list[TagOut])
def list_tags(db: Session = Depends(get_db)):
    return _tags_out(db)


@router.post("", response_model=TagOut, status_code=201)
def create_tag(data: TagCreate, db: Session = Depends(get_db)):
    existing = db.query(Tag).filter(Tag.name == data.name).first()
    if existing:
        raise HTTPException(409, "Tag already exists")
    color = data.color or next_color(db)
    tag = Tag(name=data.name, color=color, source="manual")
    db.add(tag)
    db.commit()
    db.refresh(tag)
    return tag


@router.post("/rebalance-colors", response_model=list[TagOut])
def rebalance_tag_colors(db: Session = Depends(get_db)):
    """Reassign every tag a distinct color in one pass. Fixes a library where
    many tags ended up with the same or a very similar color — either from
    the old hash-based scheme, or just from having more tags than the
    palette had room for at the time."""
    tags = db.query(Tag).all()
    colors = rebalanced([t.name for t in tags])
    for t in tags:
        t.color = colors[t.name]
    db.commit()
    return _tags_out(db)


@router.post("/restore", response_model=TagOut, status_code=201)
def restore_tag(data: TagRestore, db: Session = Depends(get_db)):
    """Recreate a tag removed via Undo and re-attach it to the given bookmarks.
    Idempotent: reuses an existing tag of the same name, and skips bookmarks
    that no longer exist or are already linked."""
    tag = db.query(Tag).filter(Tag.name == data.name).first()
    if not tag:
        tag = Tag(name=data.name, color=data.color, source="manual")
        db.add(tag)
        db.flush()
    if data.bookmark_ids:
        linked = {bid for (bid,) in db.query(BookmarkTag.bookmark_id)
                  .filter(BookmarkTag.tag_id == tag.id).all()}
        valid = {bid for (bid,) in db.query(Bookmark.id)
                 .filter(Bookmark.id.in_(data.bookmark_ids)).all()}
        for bid in valid - linked:
            db.add(BookmarkTag(bookmark_id=bid, tag_id=tag.id, source="manual"))
    db.commit()
    db.refresh(tag)
    return tag


@router.post("/merge", response_model=TagOut)
def merge_tags(data: TagMerge, db: Session = Depends(get_db)):
    """Merge tags: every bookmark tagged with a source tag gets the target tag
    instead, then the source tags are deleted. Deduplicates bookmarks that
    already carry the target. The natural cleanup for near-duplicate tags that
    LLM auto-tagging accumulates ('webdev' vs 'web development')."""
    target = db.query(Tag).filter(Tag.id == data.target_id).first()
    if not target:
        raise HTTPException(404, "Target tag not found")
    source_ids = [sid for sid in set(data.source_ids) if sid != data.target_id]
    if not source_ids:
        raise HTTPException(400, "No source tags to merge")
    sources = db.query(Tag).filter(Tag.id.in_(source_ids)).all()
    if len(sources) != len(source_ids):
        raise HTTPException(404, "A source tag was not found")

    target_links = {
        link.bookmark_id: link
        for link in db.query(BookmarkTag).filter(BookmarkTag.tag_id == target.id).all()
    }
    moved_links = db.query(BookmarkTag).filter(BookmarkTag.tag_id.in_(source_ids)).all()
    if any(source.source == "manual" for source in sources):
        target.source = "manual"
    for link in moved_links:
        existing = target_links.get(link.bookmark_id)
        if existing:
            # A manual assignment always wins when duplicate tags are merged.
            if link.source == "manual":
                existing.source = "manual"
            continue
        replacement = BookmarkTag(
            bookmark_id=link.bookmark_id,
            tag_id=target.id,
            source=link.source,
        )
        db.add(replacement)
        target_links[link.bookmark_id] = replacement
    for src in sources:
        db.delete(src)  # cascades to its BookmarkTag rows
    db.commit()
    db.refresh(target)
    return target


@router.post("/assign", response_model=list[BookmarkOut])
def assign_tags(data: BulkTagAssignment, db: Session = Depends(get_db)):
    """Apply explicit tag changes to many bookmarks in one transaction.

    Add/remove lists describe only the choices the user changed in the bulk
    editor. Unmentioned tags keep their previous state, including mixed states
    across the selection. Explicit additions are manual and therefore win over
    earlier AI assignments.
    """
    bookmark_ids = list(dict.fromkeys(data.bookmark_ids))
    add_ids = set(data.add_tag_ids)
    remove_ids = set(data.remove_tag_ids) - add_ids
    requested_tag_ids = add_ids | remove_ids

    if not bookmark_ids:
        raise HTTPException(422, "Select at least one bookmark")
    if not requested_tag_ids:
        raise HTTPException(422, "No tag changes requested")

    bookmarks = db.query(Bookmark).filter(
        Bookmark.id.in_(bookmark_ids),
        Bookmark.deleted_at.is_(None),
    ).all()
    if len(bookmarks) != len(bookmark_ids):
        raise HTTPException(404, "A selected bookmark was not found")

    valid_tag_ids = {
        tag_id for (tag_id,) in db.query(Tag.id).filter(Tag.id.in_(requested_tag_ids)).all()
    }
    if valid_tag_ids != requested_tag_ids:
        raise HTTPException(404, "A selected tag was not found")

    links = db.query(BookmarkTag).filter(
        BookmarkTag.bookmark_id.in_(bookmark_ids),
        BookmarkTag.tag_id.in_(requested_tag_ids),
    ).all()
    by_key = {(link.bookmark_id, link.tag_id): link for link in links}

    for bookmark_id in bookmark_ids:
        for tag_id in add_ids:
            existing = by_key.get((bookmark_id, tag_id))
            if existing:
                existing.source = "manual"
            else:
                db.add(BookmarkTag(
                    bookmark_id=bookmark_id,
                    tag_id=tag_id,
                    source="manual",
                ))

    if remove_ids:
        db.query(BookmarkTag).filter(
            BookmarkTag.bookmark_id.in_(bookmark_ids),
            BookmarkTag.tag_id.in_(remove_ids),
        ).delete(synchronize_session=False)

    db.commit()
    db.expire_all()
    updated = db.query(Bookmark).filter(Bookmark.id.in_(bookmark_ids)).all()
    for bookmark in updated:
        try:
            brain_sync_service.sync_bookmark(db, bookmark)
        except Exception as exc:
            # The Markdown mirror is secondary; tag assignment itself must stay
            # successful even if its configured folder is temporarily missing.
            logger.warning("Brain sync skipped after bulk tag assignment: %s", exc)
    return updated


@router.put("/{tag_id}", response_model=TagOut)
def update_tag(tag_id: str, data: TagUpdate, db: Session = Depends(get_db)):
    tag = db.query(Tag).filter(Tag.id == tag_id).first()
    if not tag:
        raise HTTPException(404, "Tag not found")
    for field, value in data.model_dump(exclude_unset=True).items():
        setattr(tag, field, value)
    db.commit()
    db.refresh(tag)
    return tag


@router.delete("/{tag_id}", status_code=204)
def delete_tag(tag_id: str, db: Session = Depends(get_db)):
    tag = db.query(Tag).filter(Tag.id == tag_id).first()
    if not tag:
        raise HTTPException(404, "Tag not found")
    db.delete(tag)
    db.commit()
