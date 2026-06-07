from fastapi import APIRouter, Depends
from fastapi.responses import Response
from sqlalchemy.orm import Session
from database import get_db
from models.bookmark import Bookmark
from models.collection import Collection
import html as html_lib

router = APIRouter(prefix="/api/export", tags=["export"])


@router.get("/html", response_class=Response)
def export_html(db: Session = Depends(get_db)):
    # Order by the user's manual folder order so the export mirrors the sidebar.
    collections = db.query(Collection).order_by(Collection.position, Collection.created_at).all()
    bookmarks   = db.query(Bookmark).order_by(Bookmark.created_at).all()

    col_by_id    = {c.id: c for c in collections}
    bms_by_col: dict[str | None, list[Bookmark]] = {}
    for bm in bookmarks:
        bms_by_col.setdefault(bm.collection_id, []).append(bm)

    lines = [
        "<!DOCTYPE NETSCAPE-Bookmark-file-1>",
        "<!-- This is an automatically generated file.",
        "     It will be read and overwritten.",
        "     DO NOT EDIT! -->",
        '<META HTTP-EQUIV="Content-Type" CONTENT="text/html; charset=UTF-8">',
        "<TITLE>Bookmarks</TITLE>",
        "<H1>Bookmarks</H1>",
        "<DL><p>",
    ]

    def _esc(s: str) -> str:
        return html_lib.escape(s or "", quote=True)

    def _write_bookmarks(col_id: str | None, indent: int) -> None:
        pad = "    " * indent
        for bm in bms_by_col.get(col_id, []):
            ts = int(bm.created_at.timestamp()) if bm.created_at else 0
            mod = int(bm.updated_at.timestamp()) if bm.updated_at else ts
            lines.append(
                f'{pad}<DT><A HREF="{_esc(bm.url)}" ADD_DATE="{ts}" LAST_MODIFIED="{mod}">{_esc(bm.title)}</A>'
            )

    def _write_folder(col: Collection, indent: int) -> None:
        pad = "    " * indent
        ts  = int(col.created_at.timestamp()) if col.created_at else 0
        lines.append(f'{pad}<DT><H3 ADD_DATE="{ts}" LAST_MODIFIED="{ts}">{_esc(col.name)}</H3>')
        lines.append(f"{pad}<DL><p>")
        _write_bookmarks(col.id, indent + 1)
        children = [c for c in collections if c.parent_id == col.id]
        for child in sorted(children, key=lambda c: c.position):
            _write_folder(child, indent + 1)
        lines.append(f"{pad}</DL><p>")

    # Root bookmarks (no collection)
    _write_bookmarks(None, 1)

    # Top-level folders
    roots = [c for c in collections if c.parent_id is None]
    for col in sorted(roots, key=lambda c: c.position):
        _write_folder(col, 1)

    lines.append("</DL><p>")
    content = "\n".join(lines)

    return Response(
        content=content,
        media_type="text/html",
        headers={"Content-Disposition": 'attachment; filename="gyrus-export.html"'},
    )
