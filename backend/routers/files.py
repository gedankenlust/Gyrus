from pathlib import Path
from fastapi import APIRouter, HTTPException
from fastapi.responses import FileResponse
from database import DATA_DIR

router = APIRouter(prefix="/api/files", tags=["files"])

# These routes are token-exempt (see main.py), so any web page could embed
# them. Favicon names are derived from the bookmarked host, which would let a
# page probe <img src=".../favicons/<hash>.png"> to learn which sites the user
# saved. CORP same-origin makes the browser refuse to hand these responses to
# a cross-origin document; native URLSession/AsyncImage ignore the header.
# nosniff stops a browser from sniffing a downloaded file into active content.
_FILE_HEADERS = {
    "Cross-Origin-Resource-Policy": "same-origin",
    "X-Content-Type-Options": "nosniff",
}


def _file_response(path: Path) -> FileResponse:
    return FileResponse(str(path), headers=_FILE_HEADERS)


def _not_found(detail: str) -> HTTPException:
    # A missing file must look exactly like a blocked one. Otherwise a page
    # could tell "absent" (plain 404, readable as an opaque no-cors response)
    # apart from "present" (rejected by CORP) and still probe the library.
    return HTTPException(404, detail, headers=_FILE_HEADERS)


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
    # SVG is active content. Reject it so the app falls back to the globe icon.
    if path is None or path.suffix.lower() == ".svg" or not path.exists():
        raise _not_found("Favicon not found")
    return _file_response(path)


@router.get("/og-images/{filename}")
def get_og_image(filename: str):
    path = _safe_path("og_images", filename)
    if path is None or not path.exists():
        raise _not_found("OG image not found")
    return _file_response(path)


@router.get("/visual-snapshots/{bookmark_id}/{filename}")
def get_visual_snapshot_file(bookmark_id: str, filename: str):
    path = _safe_nested_path("visual_snapshots", bookmark_id, filename)
    if path is None or not path.exists():
        raise _not_found("Visual snapshot file not found")
    return _file_response(path)


@router.get("/visual-snapshots/{bookmark_id}/runs/{run_id}/{filename:path}")
def get_visual_snapshot_run_file(bookmark_id: str, run_id: str, filename: str):
    path = _safe_run_artifact_path(bookmark_id, run_id, filename)
    if path is None or not path.is_file():
        raise _not_found("Visual snapshot file not found")
    return _file_response(path)
