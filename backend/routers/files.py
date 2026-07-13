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


def _safe_nested_path(subdir: str, folder: str, filename: str) -> Path | None:
    base = (DATA_DIR / subdir / Path(folder).name).resolve()
    candidate = (base / Path(filename).name).resolve()
    if candidate.parent != base:
        return None
    return candidate


def _safe_run_artifact_path(bookmark_id: str, run_id: str, filename: str) -> Path | None:
    base = (
        DATA_DIR
        / "visual_snapshots"
        / Path(bookmark_id).name
        / "runs"
        / Path(run_id).name
    ).resolve()
    candidate = (base / filename).resolve()
    if candidate != base and base not in candidate.parents:
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


@router.get("/visual-snapshots/{bookmark_id}/{filename}")
def get_visual_snapshot_file(bookmark_id: str, filename: str):
    path = _safe_nested_path("visual_snapshots", bookmark_id, filename)
    if path is None or not path.exists():
        raise HTTPException(404, "Visual snapshot file not found")
    return FileResponse(str(path))


@router.get("/visual-snapshots/{bookmark_id}/runs/{run_id}/{filename:path}")
def get_visual_snapshot_run_file(bookmark_id: str, run_id: str, filename: str):
    path = _safe_run_artifact_path(bookmark_id, run_id, filename)
    if path is None or not path.is_file():
        raise HTTPException(404, "Visual snapshot file not found")
    return FileResponse(str(path))
