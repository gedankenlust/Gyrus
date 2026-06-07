from fastapi import APIRouter, Depends, UploadFile, File, Form
from sqlalchemy.orm import Session
from database import get_db
from services.import_service import parse_netscape_html

router = APIRouter(prefix="/api/import", tags=["import"])


@router.post("/html")
async def import_html(
    file: UploadFile = File(...),
    root_folder_name: str | None = Form(None),
    db: Session = Depends(get_db),
):
    content = await file.read()
    html = content.decode("utf-8", errors="replace")
    stats = parse_netscape_html(html, db, root_folder_name=root_folder_name)
    return {"status": "ok", **stats}
