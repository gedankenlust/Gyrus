import io
from pathlib import Path

import pytest
from fastapi.testclient import TestClient
from PIL import Image

import main
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


def test_file_responses_send_nosniff_and_do_not_serve_svg(tmp_path, monkeypatch):
    monkeypatch.setattr(files, "DATA_DIR", tmp_path)
    favicons = tmp_path / "favicons"
    favicons.mkdir()
    png = io.BytesIO()
    Image.new("RGB", (1, 1), (9, 8, 7)).save(png, format="PNG")
    (favicons / "icon.png").write_bytes(png.getvalue())
    (favicons / "icon.svg").write_bytes(
        b'<svg xmlns="http://www.w3.org/2000/svg"><script>alert(1)</script></svg>'
    )
    og = tmp_path / "og_images"
    og.mkdir()
    (og / "preview.jpg").write_bytes(b"\xff\xd8\xff\xd9")

    # /api/files/ stays token-exempt: the Mac app loads images without X-Gyrus-Token.
    client = TestClient(main.app)
    ok = client.get("/api/files/favicons/icon.png")
    assert ok.status_code == 200
    assert ok.headers["x-content-type-options"] == "nosniff"
    assert ok.headers["content-type"].startswith("image/png")
    assert ok.content == png.getvalue()
    assert client.get("/api/files/favicons/icon.svg").status_code == 404

    preview = client.get("/api/files/og-images/preview.jpg")
    assert preview.status_code == 200
    assert preview.headers["x-content-type-options"] == "nosniff"
