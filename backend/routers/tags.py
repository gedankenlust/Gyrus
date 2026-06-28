from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel
from sqlalchemy import func
from sqlalchemy.orm import Session
from database import get_db
from models.tag import Tag, BookmarkTag
from models.bookmark import Bookmark
from schemas.tag import TagCreate, TagUpdate, TagOut

router = APIRouter(prefix="/api/tags", tags=["tags"])


class TagRestore(BaseModel):
    name: str
    color: str | None = None
    bookmark_ids: list[str] = []


@router.get("", response_model=list[TagOut])
def list_tags(db: Session = Depends(get_db)):
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


@router.post("", response_model=TagOut, status_code=201)
def create_tag(data: TagCreate, db: Session = Depends(get_db)):
    existing = db.query(Tag).filter(Tag.name == data.name).first()
    if existing:
        raise HTTPException(409, "Tag already exists")
    tag = Tag(**data.model_dump())
    db.add(tag)
    db.commit()
    db.refresh(tag)
    return tag


@router.post("/restore", response_model=TagOut, status_code=201)
def restore_tag(data: TagRestore, db: Session = Depends(get_db)):
    """Recreate a tag removed via Undo and re-attach it to the given bookmarks.
    Idempotent: reuses an existing tag of the same name, and skips bookmarks
    that no longer exist or are already linked."""
    tag = db.query(Tag).filter(Tag.name == data.name).first()
    if not tag:
        tag = Tag(name=data.name, color=data.color)
        db.add(tag)
        db.flush()
    if data.bookmark_ids:
        linked = {bid for (bid,) in db.query(BookmarkTag.bookmark_id)
                  .filter(BookmarkTag.tag_id == tag.id).all()}
        valid = {bid for (bid,) in db.query(Bookmark.id)
                 .filter(Bookmark.id.in_(data.bookmark_ids)).all()}
        for bid in valid - linked:
            db.add(BookmarkTag(bookmark_id=bid, tag_id=tag.id))
    db.commit()
    db.refresh(tag)
    return tag


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
