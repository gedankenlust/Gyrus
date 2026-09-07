"""Shared limits for new folders, including imports and subtree moves."""
from fastapi import HTTPException
from models.collection import Collection

MAX_NAME_LENGTH = 255
MAX_DEPTH = 64


def validate_placement(db, parent_id, *, moving_id=None):
    rows = {row.id: row.parent_id for row in db.query(Collection.id, Collection.parent_id)}
    if parent_id is not None and parent_id not in rows:
        raise HTTPException(404, "Parent folder not found")
    depth, cursor, seen = 1, parent_id, set()
    while cursor is not None:
        if cursor == moving_id or cursor in seen:
            raise HTTPException(400, "Cannot move a folder into itself or one of its descendants")
        seen.add(cursor)
        depth += 1
        cursor = rows.get(cursor)
    children = {}
    for ident, parent in rows.items():
        children.setdefault(parent, []).append(ident)
    pending = [(moving_id, depth)]
    for ident, level in pending:
        if level > MAX_DEPTH:
            raise HTTPException(422, f"Folders are limited to {MAX_DEPTH} levels")
        if ident is not None:
            pending.extend((child, level + 1) for child in children.get(ident, []))
