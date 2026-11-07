from fastapi import APIRouter, Depends, HTTPException, UploadFile, File, Form
from sqlalchemy.orm import Session
from starlette.concurrency import run_in_threadpool
from database import get_db
from services.import_service import ImportLimitExceeded, parse_netscape_html

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
    try:
        # Parsing up to 25 MB of HTML and inserting thousands of rows: run it
        # in the threadpool so the event loop (and /health) keeps answering.
        stats = await run_in_threadpool(
            parse_netscape_html, html, db, root_folder_name=root_folder_name
        )
    except ImportLimitExceeded as exc:
        raise HTTPException(status_code=413, detail=str(exc)) from exc
    imported_ids = stats.pop("_imported_ids", [])
    from services import bookmark_enrichment_service
    # Scheduled from the loop thread, as before: queuing is cheap.
    for bookmark_id in imported_ids:
        bookmark_enrichment_service.schedule_enrichment(bookmark_id)
    return {"status": "ok", **stats}
