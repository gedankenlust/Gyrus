from pathlib import Path
from fastapi import APIRouter, HTTPException
from fastapi.responses import FileResponse
from database import DATA_DIR

router = APIRouter(prefix="/api/files", tags=["files"])


def _safe_path(subdir: str, filename: str) -> Path | None:
    """Resolve a file inside DATA_DIR/subdir, rejecting any path traversal.

    Path(filename).name strips all directory components, so '../../etc/hosts'
    collapses to 'hosts' — a request can never escape the intended folder.
    """
    base = (DATA_DIR / subdir).resolve()
    candidate = (base / Path(filename).name).resolve()
    if candidate.parent != base:
        return None
    return candidate


@router.get("/favicons/{filename}")
def get_favicon(filename: str):
    path = _safe_path("favicons", filename)
    if path is None or not path.exists():
        raise HTTPException(404, "Favicon not found")
    return FileResponse(str(path))


@router.get("/og-images/{filename}")
def get_og_image(filename: str):
    path = _safe_path("og_images", filename)
    if path is None or not path.exists():
        raise HTTPException(404, "OG image not found")
    return FileResponse(str(path))
