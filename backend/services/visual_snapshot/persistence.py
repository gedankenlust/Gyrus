"""Where inspections live on disk and which run counts as current.

Layout under SNAPSHOT_DIR/<bookmark_id>/:

* ``visual_snapshot.json`` - the current (promoted) snapshot.
* ``runs/<run_id>/snapshot.json`` - every run, including failed ones, plus
  its screenshots and evidence crops.

Rules:

* A run without a single captured viewport is recorded in the history but
  never promoted, so a transient failure cannot replace a good inspection.
* Pruning keeps the newest runs and never removes the run the current
  snapshot points to (its screenshots live in that run's directory).
* JSON files are replaced atomically; readers see the old or the new
  document, never half of one.

All functions are synchronous file I/O. Async callers run them through
``asyncio.to_thread``.
"""

import json
import shutil
from datetime import datetime, timezone
from pathlib import Path
from typing import Any
from uuid import uuid4

from database import DATA_DIR
from services.atomic_write import atomic_write_text
from services.visual_snapshot.config import VIEWPORTS

SNAPSHOT_DIR = DATA_DIR / "visual_snapshots"
MAX_SNAPSHOT_RUNS = 8
CURRENT_SNAPSHOT_FILENAME = "visual_snapshot.json"
RUN_SNAPSHOT_FILENAME = "snapshot.json"
RUN_FILES_URL_PREFIX = "/api/files/visual-snapshots"


def bookmark_dir(bookmark_id: str) -> Path:
    return SNAPSHOT_DIR / bookmark_id


def snapshot_path(bookmark_id: str) -> Path:
    return bookmark_dir(bookmark_id) / CURRENT_SNAPSHOT_FILENAME


def runs_dir(bookmark_id: str) -> Path:
    return bookmark_dir(bookmark_id) / "runs"


def run_dir(bookmark_id: str, run_id: str) -> Path:
    # Path(...).name keeps a run id from the API from escaping the runs folder.
    return runs_dir(bookmark_id) / Path(run_id).name


def run_file_url(bookmark_id: str, run_id: str, relative_path: str) -> str:
    """URL under which routers/files.py serves a file of a run directory."""
    return f"{RUN_FILES_URL_PREFIX}/{bookmark_id}/runs/{run_id}/{relative_path}"


def new_snapshot_run_id() -> str:
    # Sortable by time, so a reverse name sort lists the newest run first.
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S%fZ")
    return f"{stamp}-{uuid4().hex[:8]}"


def prepare_run_dir(bookmark_id: str, run_id: str) -> Path:
    path = run_dir(bookmark_id, run_id)
    path.mkdir(parents=True, exist_ok=True)
    return path


def _read_json(path: Path) -> dict[str, Any] | None:
    if not path.exists():
        return None
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        return None


def read_snapshot(bookmark_id: str) -> dict[str, Any] | None:
    return _read_json(snapshot_path(bookmark_id))


def read_snapshot_run(bookmark_id: str, run_id: str) -> dict[str, Any] | None:
    return _read_json(run_dir(bookmark_id, run_id) / RUN_SNAPSHOT_FILENAME)


def run_summary(snapshot: dict[str, Any], fallback_run_id: str) -> dict[str, Any]:
    """One run-history row (VisualSnapshotRunDTO)."""
    viewports = snapshot.get("viewports", [])
    return {
        "run_id": snapshot.get("run_id", fallback_run_id),
        "captured_at": snapshot.get("captured_at"),
        "status": snapshot.get("status", "completed"),
        "viewport_count": len(viewports),
        "issue_count": sum(
            len(viewport.get("responsive_issues") or []) for viewport in viewports
        ),
    }


def list_snapshot_runs(bookmark_id: str) -> list[dict[str, Any]]:
    runs: list[dict[str, Any]] = []
    root = runs_dir(bookmark_id)
    if not root.exists():
        return runs
    for path in sorted(root.iterdir(), reverse=True):
        if not path.is_dir():
            continue
        snapshot = read_snapshot_run(bookmark_id, path.name)
        if not snapshot:
            continue
        runs.append(run_summary(snapshot, path.name))
    return runs


def snapshot_summary(bookmark_id: str) -> tuple[datetime | None, bool]:
    """Return capture time and whether all current viewport presets exist."""
    snapshot = read_snapshot(bookmark_id)
    if not snapshot:
        return None, False

    expected = {(item["name"], item["width"], item["height"]) for item in VIEWPORTS}
    actual = {
        (item.get("name"), item.get("width"), item.get("height"))
        for item in snapshot.get("viewports", [])
    }
    captured_at = None
    try:
        captured_at = datetime.fromisoformat(
            str(snapshot.get("captured_at", "")).replace("Z", "+00:00")
        )
    except ValueError:
        pass
    return captured_at, expected.issubset(actual)


def is_promotable(snapshot: dict[str, Any]) -> bool:
    """Only a run that captured at least one viewport may become current.

    A failed run is kept in the run history (so the app can show what went
    wrong) but a transient failure used to wipe a good inspection.
    """
    return bool(snapshot.get("viewports"))


def store_run(bookmark_id: str, snapshot: dict[str, Any]) -> None:
    """Persist a finished run, promote it if allowed, then prune old runs.

    ``snapshot["promoted"]`` is the decision recorded in the document; it is
    set from is_promotable() by the caller before the document is encoded.
    """
    encoded = json.dumps(snapshot, ensure_ascii=False, indent=2)
    atomic_write_text(run_dir(bookmark_id, snapshot["run_id"]) / RUN_SNAPSHOT_FILENAME, encoded)
    if snapshot.get("promoted"):
        atomic_write_text(snapshot_path(bookmark_id), encoded)
    prune_snapshot_runs(bookmark_id)


def prune_snapshot_runs(bookmark_id: str, keep: int | None = None) -> None:
    # Resolved at call time (not as a default argument) so a changed
    # MAX_SNAPSHOT_RUNS takes effect.
    keep = MAX_SNAPSHOT_RUNS if keep is None else keep
    root = runs_dir(bookmark_id)
    if not root.exists():
        return
    runs = sorted((path for path in root.iterdir() if path.is_dir()), reverse=True)
    # The current snapshot's screenshots live in its run directory. Failed
    # runs are not promoted, so a series of them must not prune that run.
    current_run = (read_snapshot(bookmark_id) or {}).get("run_id")
    for stale in runs[max(1, keep):]:
        if stale.name == current_run:
            continue
        shutil.rmtree(stale, ignore_errors=True)


def discard_snapshot_run(bookmark_id: str, run_id: str) -> None:
    """Delete a run that should not be kept (a cancelled inspection).

    The run the current snapshot points to is kept: a cancel that arrives
    while a finished run is being stored must not leave the current snapshot
    pointing at deleted screenshots.
    """
    if run_id == (read_snapshot(bookmark_id) or {}).get("run_id"):
        return
    shutil.rmtree(run_dir(bookmark_id, run_id), ignore_errors=True)
