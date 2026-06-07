from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel
from sqlalchemy import func
from sqlalchemy.orm import Session
from database import get_db
from models.collection import Collection
from models.bookmark import Bookmark
from schemas.collection import CollectionCreate, CollectionUpdate, CollectionOut
from services.brain_sync_service import brain_sync_service

router = APIRouter(prefix="/api/collections", tags=["collections"])


def _safe_resync(db: Session) -> None:
    """Reconcile the AI Brain folder structure after a collection change.
    Best-effort: the brain is a secondary feature and must never break core
    folder operations."""
    try:
        brain_sync_service.resync_all(db)
    except Exception as e:
        print(f"Brain resync failed: {e}")


def _next_position(db: Session, parent_id: str | None) -> int:
    """Position just past the last sibling in the given parent group."""
    max_pos = (
        db.query(func.max(Collection.position))
        .filter(Collection.parent_id == parent_id)
        .scalar()
    )
    return 0 if max_pos is None else max_pos + 1


def _build_tree(collections: list[Collection], counts: dict[str, int]) -> list[CollectionOut]:
    by_id: dict[str, CollectionOut] = {}
    for c in collections:
        node = CollectionOut.model_validate(c)
        node.children = []
        node.bookmark_count = counts.get(c.id, 0)
        by_id[c.id] = node

    roots: list[CollectionOut] = []
    for c in collections:
        node = by_id[c.id]
        if c.parent_id and c.parent_id in by_id:
            by_id[c.parent_id].children.append(node)
        else:
            roots.append(node)
    return roots


def _would_create_cycle(db: Session, collection_id: str, new_parent_id: str) -> bool:
    """True if making new_parent_id the parent of collection_id forms a cycle.

    Walks the ancestry chain upward from the proposed parent. If we reach the
    collection itself, the new parent is the collection or one of its own
    descendants — which would detach the whole subtree from the tree (it never
    becomes a root in _build_tree) and make the folder vanish from the sidebar.
    """
    cursor: str | None = new_parent_id
    while cursor is not None:
        if cursor == collection_id:
            return True
        row = db.query(Collection.parent_id).filter(Collection.id == cursor).first()
        if row is None:
            break
        cursor = row[0]
    return False


@router.get("", response_model=list[CollectionOut])
def list_collections(db: Session = Depends(get_db)):
    all_cols = db.query(Collection).order_by(Collection.position, Collection.created_at).all()
    rows = (
        db.query(Bookmark.collection_id, func.count(Bookmark.id))
        .filter(Bookmark.collection_id.is_not(None))
        .group_by(Bookmark.collection_id)
        .all()
    )
    counts = {cid: cnt for cid, cnt in rows}
    return _build_tree(all_cols, counts)


@router.post("", response_model=CollectionOut, status_code=201)
def create_collection(data: CollectionCreate, db: Session = Depends(get_db)):
    col = Collection(**data.model_dump())
    col.position = _next_position(db, col.parent_id)
    db.add(col)
    db.commit()
    db.refresh(col)
    return CollectionOut.model_validate(col)


class ReorderRequest(BaseModel):
    parent_id: str | None = None
    ordered_ids: list[str]


@router.post("/reorder")
def reorder_collections(req: ReorderRequest, db: Session = Depends(get_db)):
    """Assign positions 0..n to the given sibling IDs, in the order received."""
    for index, cid in enumerate(req.ordered_ids):
        col = db.query(Collection).filter(Collection.id == cid).first()
        if col is not None:
            col.position = index
    db.commit()
    return {"status": "ok"}


@router.put("/{collection_id}", response_model=CollectionOut)
def update_collection(collection_id: str, data: CollectionUpdate, db: Session = Depends(get_db)):
    col = db.query(Collection).filter(Collection.id == collection_id).first()
    if not col:
        raise HTTPException(404, "Collection not found")
    fields = data.model_dump(exclude_unset=True)
    if "parent_id" in fields:
        new_parent = fields["parent_id"]
        if new_parent is not None and _would_create_cycle(db, collection_id, new_parent):
            raise HTTPException(400, "Cannot move a folder into itself or one of its descendants")
        # Moved to a different parent → append to the end of the new group.
        if new_parent != col.parent_id:
            fields["position"] = _next_position(db, new_parent)
    for field, value in fields.items():
        setattr(col, field, value)
    db.commit()
    db.refresh(col)
    _safe_resync(db)
    return CollectionOut.model_validate(col)


@router.delete("/{collection_id}", status_code=204)
def delete_collection(collection_id: str, db: Session = Depends(get_db)):
    col = db.query(Collection).filter(Collection.id == collection_id).first()
    if not col:
        raise HTTPException(404, "Collection not found")
    db.delete(col)
    db.commit()
    _safe_resync(db)
