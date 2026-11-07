"""Run history, promotion and pruning rules of stored design inspections."""

import json
import os
import re

import pytest

from services import atomic_write, visual_snapshot_service
from services.visual_snapshot import persistence


@pytest.fixture
def snapshot_dir(tmp_path, monkeypatch):
    # Patched on the façade, as callers always have; the forwarding must
    # carry it into the persistence layer.
    monkeypatch.setattr(visual_snapshot_service, "SNAPSHOT_DIR", tmp_path)
    return tmp_path


def _run(run_id: str, viewports: int) -> dict:
    snapshot = {
        "bookmark_id": "bm",
        "run_id": run_id,
        "captured_at": "2026-11-07T10:00:00+00:00",
        "viewports": [{"name": f"v{index}", "responsive_issues": []} for index in range(viewports)],
        "errors": [] if viewports else [{"viewport": "desktop", "message": "offline"}],
    }
    snapshot["status"] = "completed" if viewports else "failed"
    snapshot["promoted"] = persistence.is_promotable(snapshot)
    persistence.prepare_run_dir("bm", run_id)
    return snapshot


def test_facade_patches_reach_the_persistence_layer_and_are_undone(tmp_path, monkeypatch):
    original = persistence.SNAPSHOT_DIR

    monkeypatch.setattr(visual_snapshot_service, "SNAPSHOT_DIR", tmp_path)
    assert persistence.SNAPSHOT_DIR == tmp_path
    assert visual_snapshot_service.snapshot_path("bm") == tmp_path / "bm" / "visual_snapshot.json"

    monkeypatch.undo()
    assert persistence.SNAPSHOT_DIR == original


def test_zero_viewport_run_is_recorded_but_never_replaces_the_current_snapshot(snapshot_dir):
    good = _run("20261107T100000000000Z-good", viewports=3)
    persistence.store_run("bm", good)
    failed = _run("20261107T110000000000Z-fail", viewports=0)

    persistence.store_run("bm", failed)

    assert failed["promoted"] is False
    assert visual_snapshot_service.read_snapshot("bm")["run_id"] == good["run_id"]
    assert visual_snapshot_service.read_snapshot_run("bm", failed["run_id"])["status"] == "failed"
    assert [run["run_id"] for run in visual_snapshot_service.list_snapshot_runs("bm")] == [
        failed["run_id"],
        good["run_id"],
    ]


def test_first_run_without_viewports_leaves_no_current_snapshot(snapshot_dir):
    persistence.store_run("bm", _run("20261107T100000000000Z-fail", viewports=0))

    assert visual_snapshot_service.read_snapshot("bm") is None
    assert visual_snapshot_service.snapshot_summary("bm") == (None, False)


def test_pruning_never_removes_the_run_the_current_snapshot_references(snapshot_dir):
    current = _run("20261107T090000000000Z-current", viewports=1)
    persistence.store_run("bm", current)
    for hour in range(10, 15):
        persistence.store_run("bm", _run(f"20261107T{hour}0000000000Z-fail", viewports=0))

    visual_snapshot_service._prune_snapshot_runs("bm", keep=2)

    remaining = [run["run_id"] for run in visual_snapshot_service.list_snapshot_runs("bm")]
    assert remaining == [
        "20261107T140000000000Z-fail",
        "20261107T130000000000Z-fail",
        current["run_id"],
    ]


def test_max_snapshot_runs_is_read_when_pruning(snapshot_dir, monkeypatch):
    # It used to be bound as a default argument, so changing it had no effect.
    monkeypatch.setattr(visual_snapshot_service, "MAX_SNAPSHOT_RUNS", 2)
    for hour in range(10, 14):
        persistence.store_run("bm", _run(f"20261107T{hour}0000000000Z-ok", viewports=1))

    assert len(visual_snapshot_service.list_snapshot_runs("bm")) == 2


def test_discarding_a_run_keeps_the_one_the_current_snapshot_references(snapshot_dir):
    current = _run("20261107T100000000000Z-current", viewports=1)
    persistence.store_run("bm", current)
    cancelled = _run("20261107T110000000000Z-cancelled", viewports=0)

    visual_snapshot_service.discard_snapshot_run("bm", current["run_id"])
    visual_snapshot_service.discard_snapshot_run("bm", cancelled["run_id"])

    assert persistence.run_dir("bm", current["run_id"]).is_dir()
    assert not persistence.run_dir("bm", cancelled["run_id"]).exists()


def test_store_run_writes_atomically_and_a_failed_write_keeps_the_old_snapshot(snapshot_dir, monkeypatch):
    good = _run("20261107T100000000000Z-good", viewports=1)
    persistence.store_run("bm", good)
    current_path = visual_snapshot_service.snapshot_path("bm")
    before = current_path.read_text(encoding="utf-8")

    written = []
    real_write = persistence.atomic_write_text
    monkeypatch.setattr(
        visual_snapshot_service,
        "atomic_write_text",
        lambda path, text: (written.append(path), real_write(path, text)),
    )
    newer = _run("20261107T110000000000Z-newer", viewports=1)

    def failing_replace(*_args):
        raise OSError("disk full")

    real_replace = os.replace
    monkeypatch.setattr(atomic_write.os, "replace", failing_replace)
    with pytest.raises(OSError):
        persistence.store_run("bm", newer)

    # Both documents go through the atomic writer; the run file is first, so
    # a failure leaves the current snapshot untouched and no temp files.
    assert written == [persistence.run_dir("bm", newer["run_id"]) / "snapshot.json"]
    assert current_path.read_text(encoding="utf-8") == before
    assert sorted(os.listdir(current_path.parent)) == ["runs", "visual_snapshot.json"]
    assert not [name for name in os.listdir(persistence.run_dir("bm", newer["run_id"])) if name.endswith(".tmp")]

    monkeypatch.setattr(atomic_write.os, "replace", real_replace)
    persistence.store_run("bm", newer)
    assert written[-1] == current_path
    assert json.loads(current_path.read_text(encoding="utf-8"))["run_id"] == newer["run_id"]


def test_run_ids_start_with_a_sortable_utc_timestamp():
    # Run history is listed by reverse name sort, so the id must begin with
    # a fixed-width timestamp.
    assert re.fullmatch(r"\d{8}T\d{12}Z-[0-9a-f]{8}", persistence.new_snapshot_run_id())
    assert persistence.run_dir("bm", "../../escape").name == "escape"
