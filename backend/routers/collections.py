from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel
from sqlalchemy import func
from sqlalchemy.orm import Session
from sqlalchemy.exc import IntegrityError
from services.collection_validation import validate_placement
from database import get_db
from models.collection import Collection
from models.bookmark import Bookmark
from schemas.collection import CollectionCreate, CollectionUpdate, CollectionOut
from services.brain_sync_service import brain_sync_service

import logging
logger = logging.getLogger(__name__)

router = APIRouter(prefix="/api/collections", tags=["collections"])


def _safe_resync(db: Session) -> None:
    """Reconcile the AI Brain folder structure after a collection change.
    Best-effort: the brain is a secondary feature and must never break core
    folder operations."""
    try:
        brain_sync_service.resync_all(db)
    except Exception as e:
        logger.warning(f"Brain resync failed: {e}")


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
        node = CollectionOut(**{field: getattr(c, field) for field in (
            "id", "name", "parent_id", "icon", "color", "created_at"
        )})
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
    visited: set[str] = set()
    while cursor is not None:
        if cursor in visited:
            return True
        visited.add(cursor)
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
        .filter(Bookmark.collection_id.is_not(None), Bookmark.deleted_at.is_(None))
        .group_by(Bookmark.collection_id)
        .all()
    )
    counts = {cid: cnt for cid, cnt in rows}
    return _build_tree(all_cols, counts)


@router.post("", response_model=CollectionOut, status_code=201)
def create_collection(data: CollectionCreate, db: Session = Depends(get_db)):
    validate_placement(db, data.parent_id)
    col = Collection(**data.model_dump())
    col.position = _next_position(db, col.parent_id)
    db.add(col)
    _commit_folder(db)
    db.refresh(col)
    return CollectionOut.model_validate(col)


class ReorderRequest(BaseModel):
    parent_id: str | None = None
    ordered_ids: list[str]


def _commit_folder(db):
    try:
        db.commit()
    except IntegrityError as exc:
        db.rollback()
        raise HTTPException(409, "A folder with this name already exists in this location") from exc


@router.post("/reorder")
def reorder_collections(req: ReorderRequest, db: Session = Depends(get_db)):
    """Assign positions 0..n to the given sibling IDs, in the order received."""
    siblings = {row.id for row in db.query(Collection.id).filter(Collection.parent_id == req.parent_id)}
    if len(set(req.ordered_ids)) != len(req.ordered_ids) or not set(req.ordered_ids) <= siblings:
        raise HTTPException(422, "Reordering requires distinct folders with the same parent")
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
        validate_placement(db, new_parent, moving_id=collection_id)
        if new_parent is not None and _would_create_cycle(db, collection_id, new_parent):
            raise HTTPException(400, "Cannot move a folder into itself or one of its descendants")
        # Moved to a different parent → append to the end of the new group.
        if new_parent != col.parent_id:
            fields["position"] = _next_position(db, new_parent)
    for field, value in fields.items():
        setattr(col, field, value)
    _commit_folder(db)
    db.refresh(col)
    _safe_resync(db)
    return CollectionOut.model_validate(col)


class DeleteFoldersRequest(BaseModel):
    ids: list[str]


def _folder_scope(db: Session, roots: list[str]) -> list[str]:
    """The requested folders plus every folder nested under them."""
    found: list[str] = []
    seen: set[str] = set()
    frontier = list(roots)
    while frontier:
        layer = [item for item in frontier if item not in seen]
        if not layer:
            break
        seen.update(layer)
        found.extend(layer)
        frontier = [
            row[0]
            for row in db.query(Collection.id).filter(Collection.parent_id.in_(layer)).all()
        ]
    return found


def delete_collections(db: Session, ids: list[str]) -> None:
    """Remove folders in one statement.

    Empty folders do not touch the Markdown mirror. Bookmarks that were inside
    a deleted folder stay in the library and only those notes are moved.
    """
    roots = [row[0] for row in db.query(Collection.id).filter(Collection.id.in_(ids)).all()]
    if not roots:
        raise HTTPException(404, "Collection not found")
    scope = _folder_scope(db, roots)
    scope_set = set(scope)
    parents = {
        row.id: row.parent_id
        for row in db.query(Collection.id, Collection.parent_id).filter(Collection.id.in_(scope)).all()
    }
    tops = [item for item in roots if parents.get(item) not in scope_set]
    affected = db.query(Bookmark).filter(Bookmark.collection_id.in_(scope)).all() if scope else []
    old_paths = {}
    if brain_sync_service.is_enabled:
        for bookmark in affected:
            try:
                old_paths[bookmark.id] = brain_sync_service._get_bookmark_file_path(db, bookmark)
            except Exception:
                old_paths[bookmark.id] = None
    for start in range(0, len(tops), 400):
        db.query(Collection).filter(Collection.id.in_(tops[start:start + 400])).delete(synchronize_session=False)
    db.commit()
    if not affected or not brain_sync_service.is_enabled:
        return
    db.expire_all()
    for bookmark in affected:
        try:
            db.refresh(bookmark)
            brain_sync_service.sync_bookmark(db, bookmark, old_path=old_paths.get(bookmark.id))
        except Exception as exc:
            logger.warning("Brain sync failed after folder delete: %s", exc)
    try:
        brain_sync_service.rebuild_index(db, force=True)
    except Exception as exc:
        logger.warning("Brain index failed after folder delete: %s", exc)


@router.post("/delete")
def delete_collections_route(request: DeleteFoldersRequest, db: Session = Depends(get_db)):
    delete_collections(db, request.ids)
    return {"status": "ok"}


@router.delete("/{collection_id}", status_code=204)
def delete_collection(collection_id: str, db: Session = Depends(get_db)):
    delete_collections(db, [collection_id])
