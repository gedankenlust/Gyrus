from fastapi import APIRouter, Depends, HTTPException, UploadFile, File, Form
from sqlalchemy.orm import Session
from database import get_db
from services.import_service import parse_netscape_html

router = APIRouter(prefix="/api/import", tags=["import"])
MAX_IMPORT_BYTES = 25 * 1024 * 1024


@router.post("/html")
async def import_html(
    file: UploadFile = File(...),
    root_folder_name: str | None = Form(None),
    db: Session = Depends(get_db),
):
    content = await file.read(MAX_IMPORT_BYTES + 1)
    if len(content) > MAX_IMPORT_BYTES:
        raise HTTPException(status_code=413, detail="Bookmark import is limited to 25 MB")
    html = content.decode("utf-8", errors="replace")
    stats = parse_netscape_html(html, db, root_folder_name=root_folder_name)
    imported_ids = stats.pop("_imported_ids", [])
    from services import bookmark_enrichment_service
    for bookmark_id in imported_ids:
        bookmark_enrichment_service.schedule_enrichment(bookmark_id)
    return {"status": "ok", **stats}
