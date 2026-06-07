from fastapi import APIRouter, Depends
from sqlalchemy.orm import Session
from database import get_db
from schemas.bookmark import BookmarkOut
from services.search_service import search_bookmarks

router = APIRouter(prefix="/api/search", tags=["search"])


@router.get("", response_model=list[BookmarkOut])
def search(q: str = "", limit: int = 100, offset: int = 0, db: Session = Depends(get_db)):
    results = search_bookmarks(db, q, limit=limit, offset=offset)
    out = []
    for bm in results:
        item = BookmarkOut.model_validate(bm)
        item.tags = [bt.tag for bt in bm.bookmark_tags]
        out.append(item)
    return out
