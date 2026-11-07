"""Keep blocking work off the event loop.

Every request, /health and /api/ready included, is served by one event loop.
SQLite waits up to its busy timeout (10 s) for a lock, so a single database
call inside an `async def` handler can freeze the whole backend while the app
polls it. FastAPI runs plain `def` handlers in its threadpool, which is where
synchronous work belongs; `async def` is for handlers that actually await.
"""
import ast
import sqlite3
import threading
import time
from pathlib import Path

import pytest
from fastapi import FastAPI
from fastapi.testclient import TestClient
from sqlalchemy import create_engine, event
from sqlalchemy.orm import sessionmaker

from database import Base, get_db

BACKEND_DIR = Path(__file__).resolve().parent.parent
ROUTERS_DIR = BACKEND_DIR / "routers"
ROUTE_METHODS = {"get", "post", "put", "patch", "delete", "head", "options", "api_route", "websocket"}

# "<file>.py:<handler>" entries that may stay `async def` without awaiting
# anything. Each needs a reason; prefer making the handler `def`.
ASYNC_WITHOUT_AWAIT_ALLOWLIST = {
    # Liveness probes the app polls. They do no I/O at all; on the loop they
    # answer even when every threadpool worker waits on SQLite's busy timeout.
    "main.py:health",
    "main.py:ready",
    # Must run on the loop: the check-and-set of the module's
    # _reindex_running flag is race-free only because nothing else runs on
    # the loop in between (a threadpool handler would need a lock). It does
    # no blocking work; the indexing itself is scheduled as a background
    # coroutine that moves its SQLite work to threads.
    "routers/search.py:reindex_embeddings",
}


def _is_route_decorator(node: ast.expr) -> bool:
    return (
        isinstance(node, ast.Call)
        and isinstance(node.func, ast.Attribute)
        and node.func.attr in ROUTE_METHODS
    )


def _awaits(handler: ast.AsyncFunctionDef) -> bool:
    """True when the handler body itself awaits; nested functions (e.g. a
    streaming generator defined inside) do not count."""
    pending = list(handler.body)
    while pending:
        node = pending.pop()
        if isinstance(node, (ast.Await, ast.AsyncFor, ast.AsyncWith)):
            return True
        if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef, ast.Lambda, ast.ClassDef)):
            continue
        pending.extend(ast.iter_child_nodes(node))
    return False


def _async_handlers():
    for path in [BACKEND_DIR / "main.py", *sorted(ROUTERS_DIR.glob("*.py"))]:
        tree = ast.parse(path.read_text(encoding="utf-8"), filename=str(path))
        for node in ast.walk(tree):
            if isinstance(node, ast.AsyncFunctionDef) and any(
                _is_route_decorator(decorator) for decorator in node.decorator_list
            ):
                yield f"{path.relative_to(BACKEND_DIR)}:{node.name}", node


def test_async_route_handlers_await_something():
    offenders = [
        name
        for name, handler in _async_handlers()
        if not _awaits(handler) and name not in ASYNC_WITHOUT_AWAIT_ALLOWLIST
    ]
    assert not offenders, (
        "These `async def` route handlers await nothing, so any database, file "
        "or CPU work in them blocks the event loop. Make them plain `def` "
        f"(FastAPI runs those in its threadpool): {offenders}"
    )


def test_allowlist_has_no_stale_entries():
    handlers = {name: handler for name, handler in _async_handlers()}
    stale = [
        name
        for name in ASYNC_WITHOUT_AWAIT_ALLOWLIST
        if name not in handlers or _awaits(handlers[name])
    ]
    assert not stale, f"Remove these allowlist entries: {stale}"


def test_guard_detects_an_async_handler_without_await():
    tree = ast.parse(
        "@router.get('/x')\n"
        "async def handler(db=Depends(get_db)):\n"
        "    async def inner():\n"
        "        await thing()\n"
        "    return db.query(1)\n"
    )
    handler = tree.body[0]
    assert _is_route_decorator(handler.decorator_list[0])
    assert not _awaits(handler)


# -- Behaviour: a write blocked on the SQLite lock must not stall /health ----

BUSY_TIMEOUT_MS = 4_000


@pytest.fixture
def locked_library(tmp_path, monkeypatch):
    """An app on a real SQLite file (WAL, busy timeout like production) plus a
    second, raw connection that can hold the write lock."""
    from routers import bookmarks
    from models.bookmark import Bookmark

    db_path = tmp_path / "locked.db"
    engine = create_engine(
        f"sqlite:///{db_path}", connect_args={"check_same_thread": False}
    )

    @event.listens_for(engine, "connect")
    def pragmas(conn, _):
        cursor = conn.cursor()
        cursor.execute("PRAGMA journal_mode=WAL")
        cursor.execute("PRAGMA foreign_keys=ON")
        cursor.execute(f"PRAGMA busy_timeout={BUSY_TIMEOUT_MS}")
        cursor.close()

    Base.metadata.create_all(engine)
    Session = sessionmaker(bind=engine)
    with Session() as db:
        db.add(Bookmark(
            id="cached",
            title="Cached",
            url="https://cached.example/",
            scraped_content="Readable text",
            reader_status="pending",
        ))
        db.commit()

    # Queued enrichment / indexing would touch the global test database.
    monkeypatch.setattr(
        "routers.bookmarks.bookmark_enrichment_service.schedule_enrichment",
        lambda *args, **kwargs: None,
    )
    monkeypatch.setattr(
        "routers.bookmarks.bookmark_enrichment_service.schedule_index",
        lambda *args, **kwargs: None,
    )

    app = FastAPI()
    app.include_router(bookmarks.router)

    @app.get("/health")
    def health():
        return {"status": "ok"}

    def override():
        db = Session()
        try:
            yield db
        finally:
            db.close()

    app.dependency_overrides[get_db] = override

    locker = sqlite3.connect(db_path, timeout=0, isolation_level=None, check_same_thread=False)
    with TestClient(app) as client:
        yield client, locker
    locker.close()
    engine.dispose()


@pytest.mark.parametrize(
    "method, path, body",
    [
        # Plain `def` handler (was `async def` before this guard existed).
        ("post", "/api/bookmarks", {"title": "New", "url": "https://new.example/"}),
        # `async def` handler whose database section runs in the threadpool.
        ("get", "/api/bookmarks/cached/reader", None),
    ],
)
def test_health_answers_while_a_request_waits_for_the_write_lock(locked_library, method, path, body):
    client, locker = locked_library
    locker.execute("BEGIN IMMEDIATE")  # hold the write lock
    result = {}

    def blocked_request():
        call = getattr(client, method)
        response = call(path, json=body) if body is not None else call(path)
        result["status"] = response.status_code

    worker = threading.Thread(target=blocked_request)
    try:
        worker.start()
        # Give the request time to reach the lock and start waiting on it.
        time.sleep(0.5)
        started = time.monotonic()
        health = client.get("/health")
        elapsed = time.monotonic() - started
        # The request must still be waiting: /health was answered during the
        # wait, not after it. (With the old blocking handlers, /health only
        # answered once the busy timeout had expired or the lock was gone.)
        still_waiting = worker.is_alive()
    finally:
        locker.execute("COMMIT")
        worker.join(timeout=BUSY_TIMEOUT_MS / 1000 + 5)

    assert health.status_code == 200
    assert still_waiting, "the request did not wait for the lock; the test proves nothing"
    assert elapsed < 1.0, f"/health took {elapsed:.2f}s while a write waited for the lock"
    assert not worker.is_alive()
    assert result["status"] in (200, 201)


@pytest.mark.asyncio
async def test_background_job_cancel_from_a_worker_thread_stops_the_job():
    """Cancel routes are plain `def` handlers, so BackgroundJob.cancel runs in
    the threadpool and must hand Task.cancel to the loop that owns the task."""
    import asyncio
    from services.background_job import BackgroundJob

    job = BackgroundJob(progress=0)
    started = asyncio.Event()

    async def runner(active):
        started.set()
        await asyncio.Event().wait()

    await job.start(runner)
    await asyncio.wait_for(started.wait(), 1)
    status = await asyncio.to_thread(job.cancel)
    # Whether the returned status still says "running" is a race: the loop is
    # free while the worker thread runs, and may finish the cancellation
    # before cancel() reads the state. Only the outcome below is certain.
    assert "running" in status
    for _ in range(100):
        if not job.is_running():
            break
        await asyncio.sleep(0.01)
    assert not job.is_running()
    assert job.cancelled
