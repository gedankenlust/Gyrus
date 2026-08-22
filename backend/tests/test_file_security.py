from pathlib import Path

import pytest

from routers import files


def _is_within(root: Path, candidate: Path | None) -> bool:
    return candidate is not None and (candidate == root or root in candidate.parents)


@pytest.mark.parametrize(
    "payload",
    [
        "../../etc/passwd",
        "../secrets",
        "/etc/passwd",
        "%2e%2e/%2e%2e/etc/passwd",
    ],
)
def test_file_helpers_never_escape_data_directory(tmp_path, monkeypatch, payload):
    monkeypatch.setattr(files, "DATA_DIR", tmp_path)

    candidates = [
        files._safe_path("favicons", payload),
        files._safe_nested_path("visual_snapshots", "../outside", payload),
        files._safe_run_artifact_path("../outside", "../run", payload),
    ]

    assert all(candidate is None or _is_within(tmp_path, candidate) for candidate in candidates)


def test_file_helper_rejects_symlink_escape(tmp_path, monkeypatch):
    monkeypatch.setattr(files, "DATA_DIR", tmp_path)
    outside = tmp_path.parent / "outside"
    outside.mkdir(exist_ok=True)
    base = tmp_path / "favicons"
    base.mkdir()
    (base / "escape").symlink_to(outside, target_is_directory=True)

    assert files._safe_run_artifact_path("bookmark", "run", "../../../../outside/file") is None
    assert files._safe_path("favicons", "escape") is None
