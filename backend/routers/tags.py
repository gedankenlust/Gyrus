from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy import func
from sqlalchemy.orm import Session
from database import get_db
from models.tag import Tag, BookmarkTag
from models.bookmark import Bookmark
from schemas.tag import TagCreate, TagUpdate, TagOut

router = APIRouter(prefix="/api/tags", tags=["tags"])


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
