"""Regressions for the phase-1 correctness review (one section per finding)."""
import asyncio
import io
import os
import subprocess
import sys
import threading
from datetime import datetime, timezone
from unittest.mock import AsyncMock

import httpx
import pytest
from fastapi import FastAPI
from fastapi.testclient import TestClient
from sqlalchemy import event, insert
from sqlalchemy.orm import sessionmaker

import main
from database import DATA_DIR
from models.bookmark import Bookmark
from models.tag import BookmarkTag
from services import bookmark_enrichment_service, parent_watchdog
from services import llm_service as llm_module
from services.brain_sync_service import brain_sync_service


@pytest.fixture
def no_enrichment(monkeypatch):
    scheduled = []
    monkeypatch.setattr(
        bookmark_enrichment_service,
        "schedule_enrichment",
        lambda bookmark_id, **kwargs: scheduled.append(bookmark_id),
    )
    return scheduled


# --- 1. /api/files responses must not be readable cross-origin -------------

def test_file_responses_forbid_cross_origin_embedding(client):
    files = {
        "/api/files/favicons/0123456789abcdef.png": DATA_DIR / "favicons" / "0123456789abcdef.png",
        "/api/files/og-images/preview.jpg": DATA_DIR / "og_images" / "preview.jpg",
        "/api/files/visual-snapshots/corp-bm/desktop.png":
            DATA_DIR / "visual_snapshots" / "corp-bm" / "desktop.png",
        "/api/files/visual-snapshots/corp-bm/runs/run-1/desktop.png":
            DATA_DIR / "visual_snapshots" / "corp-bm" / "runs" / "run-1" / "desktop.png",
    }
    for path in files.values():
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(b"\x89PNG\r\n\x1a\n")

    for url in files:
        response = client.get(url)
        assert response.status_code == 200, url
        assert response.headers["cross-origin-resource-policy"] == "same-origin"
        assert response.headers["x-content-type-options"] == "nosniff"

    # "Absent" must be indistinguishable from "present but blocked".
    missing = client.get("/api/files/favicons/ffffffffffffffff.png")
    assert missing.status_code == 404
    assert missing.headers["cross-origin-resource-policy"] == "same-origin"


# --- 3. Restore uploads get their own, larger body limit --------------------

@pytest.fixture
def app_client(monkeypatch):
    monkeypatch.setattr(main, "MAX_REQUEST_BYTES", 2_000)
    monkeypatch.setattr(main, "MAX_RESTORE_REQUEST_BYTES", 200_000)
    client = TestClient(main.app, headers={"X-Gyrus-Token": main.API_TOKEN})
    try:
        yield client
    finally:
        client.close()


def _restore_payload(title_size: int) -> dict:
    return {
        "version": 1, "collections": [], "tags": [],
        "bookmarks": [{"id": "big", "title": "x" * title_size, "url": "https://example.com"}],
    }


def test_restore_routes_accept_bodies_above_the_general_limit(app_client):
    payload = _restore_payload(20_000)
    response = app_client.post("/api/data/restore/preview", json=payload)
    assert response.status_code == 200
    assert response.json()["bookmarks"] == 1

    # The general limit still applies everywhere else.
    other = app_client.post("/api/bookmarks", json={"title": "x" * 20_000, "url": "https://e.com"})
    assert other.status_code == 413

    # And the restore limit is still a limit.
    huge = app_client.post("/api/data/restore/preview", json=_restore_payload(300_000))
    assert huge.status_code == 413


def test_restore_limit_also_applies_to_chunked_bodies(app_client):
    import json
    body = json.dumps(_restore_payload(20_000)).encode()
    chunks = [body[i:i + 4096] for i in range(0, len(body), 4096)]
    response = app_client.post(
        "/api/data/restore/preview", content=iter(chunks),
        headers={"Content-Type": "application/json"},
    )
    assert response.status_code == 200
    other = app_client.post(
        "/api/bookmarks", content=iter(chunks), headers={"Content-Type": "application/json"}
    )
    assert other.status_code == 413


def test_restore_path_matching_is_exact():
    assert main.request_byte_limit("/api/data/restore") == main.MAX_RESTORE_REQUEST_BYTES
    assert main.request_byte_limit("/api/data/restore/preview") == main.MAX_RESTORE_REQUEST_BYTES
    assert main.request_byte_limit("/api/data/restorex") == main.MAX_REQUEST_BYTES
    assert main.request_byte_limit("/api/bookmarks") == main.MAX_REQUEST_BYTES


# --- 4. OFFSET pagination has a unique tiebreaker ---------------------------

@pytest.mark.parametrize("sort_by,order", [
    ("created_at", "desc"), ("created_at", "asc"), ("title", "asc"),
    ("title", "desc"), ("favicon", "asc"), ("tag", "asc"), ("tag", "desc"),
    ("updated_at", "desc"), ("url", "asc"),
])
def test_pages_never_repeat_or_skip_tied_rows(client, db, sort_by, order):
    from models.tag import Tag
    stamp = datetime(2026, 1, 1, tzinfo=timezone.utc)
    ids = [f"tie-{n:02d}" for n in range(11)]
    url_of = {ident: f"https://same.example/{n}" for n, ident in enumerate(ids)}
    # Insert out of id order so storage order cannot mask a missing tiebreaker.
    insertion = ids[5:] + ids[:5][::-1]
    db.execute(insert(Bookmark), [
        {"id": ident, "title": "Same", "url": url_of[ident],
         "created_at": stamp, "updated_at": stamp}
        for ident in insertion
    ])
    db.add(Tag(id="tie-tag", name="tied"))
    db.flush()
    db.execute(insert(BookmarkTag), [
        {"bookmark_id": ident, "tag_id": "tie-tag", "source": "manual"} for ident in ids[:6]
    ])
    db.commit()

    seen = []
    for offset in range(0, len(ids), 2):
        page = client.get("/api/bookmarks", params={
            "limit": 2, "offset": offset, "sort_by": sort_by, "order": order,
        })
        assert page.status_code == 200
        seen.extend(item["id"] for item in page.json())
    assert len(seen) == len(ids)
    assert set(seen) == set(ids)
    # Ties are broken by id, so the order is fully determined.
    if sort_by == "url":
        expected = sorted(ids, key=lambda ident: url_of[ident])
    elif sort_by == "tag":
        expected = sorted(ids[:6]) + sorted(ids[6:])
    else:
        expected = sorted(ids)
    assert seen == expected


def test_unknown_sort_parameters_are_rejected(client):
    assert client.get("/api/bookmarks", params={"sort_by": "bogus"}).status_code == 422
    assert client.get("/api/bookmarks", params={"order": "sideways"}).status_code == 422
    assert client.get("/api/bookmarks", params={"sort_by": "favicon", "order": "asc"}).status_code == 200


# --- 5. Unknown folder/tag ids are a 422, not a fake duplicate or a 500 -----

def test_create_with_unknown_references_is_422(client, no_enrichment):
    base = {"title": "Ref", "url": "https://refs.example/"}
    missing_folder = client.post("/api/bookmarks", json={**base, "collection_id": "nope"})
    assert missing_folder.status_code == 422
    assert missing_folder.json()["detail"] == "Collection not found"
    missing_tag = client.post("/api/bookmarks", json={**base, "tag_ids": ["nope"]})
    assert missing_tag.status_code == 422
    assert missing_tag.json()["detail"] == "One or more tags were not found"
    assert client.get("/api/bookmarks/count").json() == 0


def test_update_with_unknown_references_is_422(client, no_enrichment):
    tag = client.post("/api/tags", json={"name": "kept"}).json()
    bm = client.post("/api/bookmarks", json={
        "title": "Ref", "url": "https://refs.example/", "tag_ids": [tag["id"], tag["id"]],
    })
    assert bm.status_code == 201
    bm = bm.json()
    assert client.put(f"/api/bookmarks/{bm['id']}", json={"collection_id": "nope"}).status_code == 422
    assert client.put(f"/api/bookmarks/{bm['id']}", json={"tag_ids": ["nope"]}).status_code == 422
    after = client.get(f"/api/bookmarks/{bm['id']}").json()
    assert after["collection_id"] is None
    assert [t["id"] for t in after["tags"]] == [tag["id"]]
    # Moving to the root stays valid.
    assert client.put(f"/api/bookmarks/{bm['id']}", json={"collection_id": None}).status_code == 200


# --- 6. Saving a trashed URL again restores it ------------------------------

def test_readding_a_trashed_url_restores_it(client, no_enrichment):
    folder = client.post("/api/collections", json={"name": "Later"}).json()
    tag = client.post("/api/tags", json={"name": "again"}).json()
    original = client.post("/api/bookmarks", json={
        "title": "Old title", "url": "https://trashed.example/", "description": "kept",
    }).json()
    client.post(f"/api/bookmarks/{original['id']}/notes", json={"content": "my note"})
    assert client.delete(f"/api/bookmarks/{original['id']}").status_code == 204

    again = client.post("/api/bookmarks", json={
        "title": "New title", "url": "https://trashed.example/",
        "collection_id": folder["id"], "tag_ids": [tag["id"]],
    })
    assert again.status_code == 201
    assert again.headers["x-gyrus-restored-from-trash"] == "true"
    body = again.json()
    assert body["id"] == original["id"]
    assert body["title"] == "New title"
    assert body["description"] == "kept"
    assert body["collection_id"] == folder["id"]
    assert [t["id"] for t in body["tags"]] == [tag["id"]]
    assert [n["content"] for n in body["bookmark_notes"]] == ["my note"]
    assert client.get("/api/bookmarks/trash/count").json() == 0
    assert no_enrichment == [original["id"], original["id"]]

    # An active duplicate is still a conflict.
    duplicate = client.post("/api/bookmarks", json={"title": "Dup", "url": "https://trashed.example/"})
    assert duplicate.status_code == 409


def test_readding_a_trashed_url_from_the_extension_keeps_inbox_rule(client, no_enrichment):
    original = client.post("/api/bookmarks", json={
        "title": "Old", "url": "https://ext.example/", "source": "extension",
    }).json()
    inbox_id = original["collection_id"]
    client.post("/api/bookmarks/delete-batch", json={"ids": [original["id"]]})
    again = client.post("/api/bookmarks", json={
        "title": "New", "url": "https://ext.example/", "source": "extension",
    })
    assert again.status_code == 201
    assert again.json()["collection_id"] == inbox_id


def test_import_restores_trashed_bookmarks_and_counts_them(client, no_enrichment):
    original = client.post("/api/bookmarks", json={
        "title": "Before", "url": "https://imported-again.example/",
    }).json()
    client.delete(f"/api/bookmarks/{original['id']}")
    html = (
        b'<DL><p><DT><H3>Browser</H3><DL><p>'
        b'<DT><A HREF="https://imported-again.example/">After</A>'
        b'<DT><A HREF="https://brand-new.example/">New</A>'
        b'</DL><p></DL>'
    )
    response = client.post(
        "/api/import/html", files={"file": ("bookmarks.html", io.BytesIO(html), "text/html")}
    )
    assert response.status_code == 200
    stats = response.json()
    assert stats["imported"] == 1
    assert stats["restored"] == 1
    assert stats["skipped"] == 0
    restored = client.get(f"/api/bookmarks/{original['id']}").json()
    assert restored["title"] == "After"
    folder = next(c for c in client.get("/api/collections").json() if c["name"] == "Browser")
    assert restored["collection_id"] == folder["id"]
    assert original["id"] in no_enrichment

    # Importing the same file again skips both (now active) bookmarks.
    again = client.post(
        "/api/import/html", files={"file": ("bookmarks.html", io.BytesIO(html), "text/html")}
    ).json()
    assert (again["imported"], again["restored"], again["skipped"]) == (0, 0, 2)


# --- 7. Id lists beyond SQLite's 32,766 bound-parameter limit ---------------

SQLITE_MAX_VARIABLES = 32_766


def test_bulk_trash_restore_and_purge_accept_huge_selections(client, db, no_enrichment):
    real = [
        client.post("/api/bookmarks", json={"title": f"R{n}", "url": f"https://bulk.example/{n}"}).json()["id"]
        for n in range(3)
    ]
    ids = [f"missing-{n}" for n in range(SQLITE_MAX_VARIABLES + 500)] + real

    assert client.post("/api/bookmarks/delete-batch", json={"ids": ids}).status_code == 204
    assert client.get("/api/bookmarks/trash/count").json() == 3
    assert client.post("/api/bookmarks/trash/restore", json={"ids": ids}).json() == {"restored": 3}
    assert client.get("/api/bookmarks/count").json() == 3
    client.post("/api/bookmarks/delete-batch", json={"ids": real})
    assert client.post("/api/bookmarks/trash/purge", json={"ids": ids}).json() == {"purged": 3}
    assert db.query(Bookmark).count() == 0


def test_taxonomy_apply_accepts_huge_selections(client, db, no_enrichment):
    from services import taxonomy_service
    bm = client.post("/api/bookmarks", json={"title": "T", "url": "https://tax.example/"}).json()
    taxonomy_service._drafts["huge"] = {
        "id": "huge",
        "tags": [{"id": "t1", "name": "topic", "bookmark_ids": [bm["id"]]}],
        "untagged": [{"id": f"missing-{n}"} for n in range(SQLITE_MAX_VARIABLES + 500)],
        "total": SQLITE_MAX_VARIABLES + 501,
    }
    result = taxonomy_service.apply_draft(db, "huge", [])
    assert result["assignments"] == 1
    assert [t["name"] for t in client.get(f"/api/bookmarks/{bm['id']}").json()["tags"]] == ["topic"]


def test_resume_pending_does_not_bind_every_id(db, monkeypatch):
    rows = 1_200
    db.execute(insert(Bookmark), [
        {"id": f"resume-{n}", "title": "R", "url": f"https://resume.example/{n}",
         "metadata_status": "running", "reader_status": "running", "index_status": "running"}
        for n in range(rows)
    ])
    db.commit()
    scheduled = []
    monkeypatch.setattr(
        bookmark_enrichment_service, "SessionLocal", sessionmaker(bind=db.get_bind())
    )
    monkeypatch.setattr(
        bookmark_enrichment_service, "schedule_enrichment",
        lambda bookmark_id, **kwargs: scheduled.append(bookmark_id),
    )
    widest = []

    def record(conn, cursor, statement, parameters, context, executemany):
        if statement.lstrip().upper().startswith("UPDATE"):
            widest.append(len(parameters or ()))

    engine = db.get_bind()
    event.listen(engine, "before_cursor_execute", record)
    try:
        assert bookmark_enrichment_service.resume_pending() == rows
    finally:
        event.remove(engine, "before_cursor_execute", record)

    assert widest and max(widest) < 10
    assert len(scheduled) == rows
    db.expire_all()
    statuses = {
        (b.metadata_status, b.reader_status, b.index_status) for b in db.query(Bookmark).all()
    }
    assert statuses == {("pending", "pending", "pending")}


# --- 9. SQLite waits for a busy writer instead of failing at once -----------

def test_app_engine_sets_busy_timeout_and_keeps_pragmas():
    from database import BUSY_TIMEOUT_MS, engine
    with engine.connect() as connection:
        assert connection.exec_driver_sql("PRAGMA busy_timeout").scalar() == BUSY_TIMEOUT_MS
        assert connection.exec_driver_sql("PRAGMA foreign_keys").scalar() == 1
        assert connection.exec_driver_sql("PRAGMA journal_mode").scalar() == "wal"
    assert BUSY_TIMEOUT_MS >= 5_000


# --- 10. Read-only requests do not block maintenance ------------------------

@pytest.mark.asyncio
async def test_in_flight_reads_do_not_block_reservations():
    from services.maintenance import MaintenanceMiddleware, reserve
    app = FastAPI()
    app.add_middleware(MaintenanceMiddleware)
    started, finish = asyncio.Event(), asyncio.Event()

    @app.get("/api/status-poll")
    async def status_poll():
        started.set()
        await finish.wait()
        return {"status": "ok"}

    @app.post("/api/slow-write")
    async def slow_write():
        started.set()
        await finish.wait()
        return {"status": "ok"}

    @app.post("/api/replace")
    async def replace():
        reserve()
        return {"status": "ok"}

    transport = httpx.ASGITransport(app=app)
    async with httpx.AsyncClient(transport=transport, base_url="http://test") as client:
        poll = asyncio.create_task(client.get("/api/status-poll"))
        await started.wait()
        try:
            assert (await client.post("/api/replace")).status_code == 200
        finally:
            finish.set()
        assert (await poll).status_code == 200

        # A write that is still running keeps blocking, as before.
        started.clear()
        finish.clear()
        write = asyncio.create_task(client.post("/api/slow-write"))
        await started.wait()
        try:
            assert (await client.post("/api/replace")).status_code == 409
        finally:
            finish.set()
        assert (await write).status_code == 200


# --- 11. A restore refetches icons through the enrichment pipeline ----------

def test_restore_requeues_metadata_for_active_bookmarks(client, db, no_enrichment):
    payload = {
        "version": 2, "collections": [], "tags": [],
        "bookmarks": [
            {"id": "active", "title": "A", "url": "https://active.example/",
             "metadata_status": "ready", "reader_status": "not_requested",
             "favicon_path": "abcdef.png", "og_image_path": "x.jpg"},
            {"id": "trashed", "title": "T", "url": "https://trashed-restore.example/",
             "metadata_status": "ready", "deleted_at": datetime.now(timezone.utc).isoformat()},
        ],
    }
    assert client.post("/api/data/restore", json=payload).status_code == 200
    active = db.get(Bookmark, "active")
    assert active.favicon_path is None and active.og_image_path is None
    assert active.metadata_status == "pending"
    assert active.reader_status == "not_requested"
    assert db.get(Bookmark, "trashed").metadata_status == "ready"
    assert no_enrichment == ["active"]


@pytest.mark.asyncio
async def test_metadata_requeue_does_not_crawl_unrequested_reader(db, monkeypatch):
    bookmark = Bookmark(
        title="Restored", url="https://restored.example",
        metadata_status="pending", reader_status="not_requested",
    )
    db.add(bookmark)
    db.commit()
    fetch = AsyncMock(return_value={"favicon_path": "icon.png"})
    scrape = AsyncMock(return_value={"content": "should not be fetched"})
    monkeypatch.setattr("services.bookmark_enrichment_service.metadata_service.fetch_metadata", fetch)
    monkeypatch.setattr("services.scraper_service.scraper_service.extract_content", scrape)
    monkeypatch.setattr(
        "services.bookmark_enrichment_service.SessionLocal", sessionmaker(bind=db.get_bind())
    )

    await bookmark_enrichment_service.enrich_bookmark(bookmark.id)

    db.expire_all()
    updated = db.get(Bookmark, bookmark.id)
    assert fetch.await_count == 1
    assert scrape.await_count == 0
    assert updated.metadata_status == "ready"
    assert updated.favicon_path == "icon.png"
    assert updated.reader_status == "not_requested"


# --- 12. 404 instead of refresh(None); no raw exception text; reset safety --

def test_retry_analysis_for_vanished_bookmark_is_404(client, monkeypatch):
    monkeypatch.setattr(bookmark_enrichment_service, "retry", lambda bookmark_id: True)
    response = client.post("/api/bookmarks/vanished/analysis/retry")
    assert response.status_code == 404


SECRET = "/Users/someone/.gyrus/db/gyrus.db: secret provider body"


@pytest.fixture
def failing_llm(monkeypatch, tmp_path):
    async def boom(*args, **kwargs):
        raise RuntimeError(SECRET)

    async def boom_stream(*args, **kwargs):
        raise RuntimeError(SECRET)
        yield  # pragma: no cover

    async def scrape(url):
        return {"content": "Readable page content for the model.", "title": "T", "error": None}

    from services import scraper_service as scraper_module
    monkeypatch.setattr(llm_module.LLMService, "ask_llm", boom)
    monkeypatch.setattr(llm_module.LLMService, "stream_ollama", boom_stream)
    monkeypatch.setattr(scraper_module.scraper_service, "extract_content", scrape)
    brain_sync_service.update_config(str(tmp_path), True)


def test_llm_failures_do_not_leak_exception_text(client, db, failing_llm, no_enrichment):
    bm = client.post("/api/bookmarks", json={"title": "LLM", "url": "https://llm.example/"}).json()
    stored = db.get(Bookmark, bm["id"])
    stored.scraped_content = "Readable page content for the model."
    db.commit()
    responses = [
        client.post(f"/api/bookmarks/{bm['id']}/reader/cleanup", json={}),
        client.post(f"/api/bookmarks/{bm['id']}/reader/translate", json={"content": "Hallo"}),
        client.post(f"/api/bookmarks/{bm['id']}/auto-tag", json={}),
        client.post("/api/brain/chat", json={"bookmark_id": bm["id"], "prompt": "hi"}),
        client.post(f"/api/brain/summarize/{bm['id']}"),
        client.post("/api/brain/chat/stream", json={
            "bookmark_id": bm["id"], "prompt": "hi",
            "provider_config": {"provider": "ollama", "model": "llama3"},
        }),
    ]
    for response in responses:
        assert ".gyrus" not in response.text, response.request.url
        assert "secret provider body" not in response.text
    assert responses[-1].status_code == 200 and "[GYRUS-ERROR]" in responses[-1].text
    assert all(r.status_code in (500, 502) for r in responses[:-1])
    messages = client.get(f"/api/brain/bookmarks/{bm['id']}/messages").json()
    assert messages and all(SECRET not in m["content"] for m in messages)


@pytest.mark.asyncio
async def test_folder_move_failure_does_not_expose_paths(monkeypatch):
    from services import folder_organize_service as organize

    class NoRest:
        def __init__(self, *args, **kwargs):
            pass

        async def rest(self, *args, **kwargs):
            return None

    bookmarks = [{"id": f"b{n}", "title": f"T{n}", "url": f"https://s{n}.example/"} for n in range(4)]
    structure = [{"name": f"Folder {n}", "children": []} for n in range(4)]
    monkeypatch.setattr(organize, "_load_rows", lambda: (bookmarks, []))
    monkeypatch.setattr(organize, "link_folders", lambda rows: {})
    monkeypatch.setattr(organize, "_propose", AsyncMock(return_value=(structure, 0)))
    monkeypatch.setattr(
        organize, "_assign_batch",
        AsyncMock(side_effect=lambda batch, paths, *a: ([paths[0]] * len(batch), 0)),
    )
    monkeypatch.setattr(organize, "TaggingPacer", NoRest)

    def failing_backup():
        raise OSError(f"Permission denied: {SECRET}")

    monkeypatch.setattr(organize, "_backup", failing_backup)
    await organize._run(None, "en")
    assert organize.job.state["phase"] == "error"
    assert ".gyrus" not in organize.job.state["message"]


def test_factory_reset_with_unsafe_brain_root_completes(client, db, monkeypatch, no_enrichment):
    from services import ai_policy

    def unsafe():
        raise ValueError("Refusing to clear unsafe Brain root: /Users/someone")

    def must_not_run():
        raise AssertionError("unsafe Brain root must never be swept")

    monkeypatch.setattr(brain_sync_service, "clearable_root", unsafe)
    monkeypatch.setattr(brain_sync_service, "clear_all_files", must_not_run)
    client.post("/api/bookmarks", json={"title": "Gone", "url": "https://reset.example/"})
    leftover = DATA_DIR / "og_images" / "reset-leftover.jpg"
    leftover.write_bytes(b"x")

    response = client.post("/api/data/factory-reset")
    assert response.status_code == 200
    assert response.json() == {"status": "ok", "brain_files_cleared": False}
    assert client.get("/api/bookmarks/count").json() == 0
    assert not leftover.exists()
    assert not ai_policy.enabled()


def test_clear_brain_with_unsafe_root_is_a_clear_409(client, monkeypatch):
    def unsafe():
        raise ValueError("Refusing to clear unsafe Brain root: /Users/someone")

    monkeypatch.setattr(brain_sync_service, "clear_all_files", unsafe)
    response = client.post("/api/data/clear-brain")
    assert response.status_code == 409
    assert "/Users/someone" not in response.text


# --- 13. Parent watchdog ------------------------------------------------------

def test_parent_pid_parsing():
    env = parent_watchdog.PARENT_PID_ENV
    assert parent_watchdog.parent_pid_from_env({}) is None
    assert parent_watchdog.parent_pid_from_env({env: ""}) is None
    assert parent_watchdog.parent_pid_from_env({env: "abc"}) is None
    assert parent_watchdog.parent_pid_from_env({env: "1"}) is None
    assert parent_watchdog.parent_pid_from_env({env: " 4321 "}) == 4321
    assert parent_watchdog.start_parent_watchdog({}) is None


def test_parent_alive_detects_exited_process():
    assert parent_watchdog.parent_alive(os.getpid()) is True
    child = subprocess.Popen([sys.executable, "-c", "pass"])
    child.wait()
    assert parent_watchdog.parent_alive(child.pid) is False
    # Re-parenting is authoritative when the app was the direct parent.
    assert parent_watchdog.parent_alive(os.getpid(), was_direct_parent=True) is False


def test_watchdog_triggers_shutdown_once_parent_is_gone():
    checks = []
    exited = threading.Event()

    def alive(pid, *, was_direct_parent):
        checks.append(pid)
        return len(checks) < 3

    parent_watchdog.watch_parent(
        4321, interval=0.001, on_parent_exit=exited.set, is_alive=alive
    )
    assert exited.is_set()
    assert checks == [4321, 4321, 4321]


def test_watchdog_thread_stops_without_signalling(monkeypatch):
    signalled = []
    monkeypatch.setattr(parent_watchdog, "_terminate_self", lambda: signalled.append(True))
    stop = parent_watchdog.start_parent_watchdog(
        {parent_watchdog.PARENT_PID_ENV: str(os.getpid())}
    )
    assert stop is not None
    stop.set()
    assert signalled == []


# --- 2. Scraper/metadata callers stay sane with the new egress outcomes -----

def _nxdomain(*_args, **_kwargs):
    import socket
    raise socket.gaierror(socket.EAI_NONAME, "not known")


@pytest.mark.asyncio
async def test_scraper_reports_unresolvable_host_without_raising(monkeypatch):
    import socket
    from services.scraper_service import scraper_service
    monkeypatch.setattr(socket, "getaddrinfo", _nxdomain)
    result = await scraper_service.extract_content("https://gone.example/")
    assert result["content"] == ""
    assert "could not be resolved" in result["error"]


@pytest.mark.asyncio
async def test_scraper_maps_refused_upstream_to_unreachable(monkeypatch):
    import socket
    from services.safe_egress_proxy import SafeEgressProxy
    from services.scraper_service import scraper_service

    with socket.socket() as probe:
        probe.bind(("127.0.0.1", 0))
        closed_port = probe.getsockname()[1]

    async def refused(_address, _port):
        return await asyncio.open_connection("127.0.0.1", closed_port)

    monkeypatch.setattr(
        socket, "getaddrinfo",
        lambda host, port, *a, **k: [(socket.AF_INET, socket.SOCK_STREAM, 6, "", ("93.184.216.34", port))],
    )
    monkeypatch.setattr(SafeEgressProxy, "_connect", staticmethod(refused))
    for url in ("https://refused.example/", "http://refused.example/"):
        result = await scraper_service.extract_content(url)
        assert result["error"] == "Website could not be reached", url


@pytest.mark.asyncio
async def test_metadata_fetch_survives_unresolvable_host(monkeypatch):
    import socket
    from services import metadata_service
    monkeypatch.setattr(socket, "getaddrinfo", _nxdomain)
    meta = await metadata_service.fetch_metadata("https://gone.example/")
    assert isinstance(meta, dict)
