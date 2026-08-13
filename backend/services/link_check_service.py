"""
Dead-link detection.

Runs as a background asyncio task; stores progress in a module-level dict
so the API can poll it. One run at a time — if already running, /start is a no-op.
"""
import asyncio
import ipaddress
import logging
import ssl
import httpx
from urllib.parse import urlparse
from database import SessionLocal
from models.bookmark import Bookmark
from services.background_job import BackgroundJob
from services.outbound_url_security import OutboundURLBlocked, strict_public_request_guard


logger = logging.getLogger(__name__)


def is_local_host(url: str) -> bool:
    """True for localhost / loopback / private-LAN / .local / bare hostnames.

    Whether such a URL "works" depends on a local server being up right now —
    that's transient, not a property of the bookmark — so these must never be
    flagged as dead links.
    """
    try:
        host = (urlparse(url).hostname or "").lower()
    except ValueError:
        return False
    if not host:
        return False
    if host in {"localhost", "0.0.0.0"} or host.endswith(".local"):
        return True
    try:
        ip = ipaddress.ip_address(host)
        return ip.is_loopback or ip.is_private or ip.is_link_local
    except ValueError:
        pass
    # A single-label hostname (no dot) is a local network name, not a public site.
    return "." not in host


CONCURRENCY = 20
TIMEOUT = 10.0
RETRIES = 3
RETRY_DELAY = 1.5

job = BackgroundJob(checked=0, total=0, dead_found=0)

get_status = job.get_status
is_running = job.is_running
cancel = job.cancel


def _caused_by_ssl_error(exc: BaseException) -> bool:
    current: BaseException | None = exc
    seen: set[int] = set()
    while current is not None and id(current) not in seen:
        if isinstance(current, ssl.SSLError):
            return True
        seen.add(id(current))
        current = current.__cause__ or current.__context__
    return False


async def _check_url(client: httpx.AsyncClient, url: str) -> bool | None:
    """Returns True only when the URL is reliably dead.

    Dead means a definitive 404/410, or a connection failure (DNS /
    refused) that persists across every retry. Timeouts and other
    transient network errors return None after retries, leaving the
    bookmark's previous status unchanged.
    Marking dead on a single timeout produces different results on every
    run and causes healthy bookmarks to be flagged and deleted.
    """
    # Local / private addresses depend on a transient local server being up —
    # never treat them as dead links.
    if is_local_host(url):
        return False
    for attempt in range(RETRIES):
        try:
            # HEAD first to save bandwidth
            r = await client.head(url, follow_redirects=True, timeout=TIMEOUT)
            if r.status_code in (404, 410):
                return True
            # Some servers don't support HEAD; if we got a non-2xx/3xx, fall back to GET
            if r.status_code >= 400 and r.status_code not in (401, 403, 429):
                r = await client.get(url, follow_redirects=True, timeout=TIMEOUT)
                if r.status_code in (404, 410):
                    return True
            return False  # got a response → the link is alive
        except httpx.ConnectError as exc:
            # DNS failure / connection refused — can be transient under load.
            # Retry; only count as dead if it never connects.
            if _caused_by_ssl_error(exc):
                logger.info("TLS validation failed for %s; keeping prior status", url)
                return None
            if attempt == RETRIES - 1:
                return True
            await asyncio.sleep(RETRY_DELAY)
        except httpx.RequestError:
            # Timeout or other transient network error — retry, but never
            # mark dead on this alone. A slow server is not a dead link.
            if attempt == RETRIES - 1:
                return None
            await asyncio.sleep(RETRY_DELAY)
        except OutboundURLBlocked as exc:
            logger.warning("Link check skipped blocked URL %s: %s", url, exc)
            return None
    return None


def _load_rows() -> list[tuple[str, str]]:
    db = SessionLocal()
    try:
        return [
            (bookmark.id, bookmark.url)
            for bookmark in db.query(Bookmark)
            .filter(Bookmark.deleted_at.is_(None))
            .all()
        ]
    finally:
        db.close()


def _bookmark_count() -> int:
    db = SessionLocal()
    try:
        return db.query(Bookmark).filter(Bookmark.deleted_at.is_(None)).count()
    finally:
        db.close()


def _persist_results(results: list[tuple[str, bool]]) -> None:
    """Persist completed checks in bounded batches without N+1 queries."""
    if not results:
        return

    ids_dead = [k for k, v in results if v]
    ids_alive = [k for k, v in results if not v]

    db = SessionLocal()
    try:
        # SQLite commonly limits bound parameters to 999.
        for start in range(0, len(ids_dead), 500):
            chunk = ids_dead[start:start + 500]
            db.query(Bookmark).filter(Bookmark.id.in_(chunk), Bookmark.is_dead != True).update({"is_dead": True}, synchronize_session=False)

        for start in range(0, len(ids_alive), 500):
            chunk = ids_alive[start:start + 500]
            db.query(Bookmark).filter(Bookmark.id.in_(chunk), Bookmark.is_dead != False).update({"is_dead": False}, synchronize_session=False)

        db.commit()
    finally:
        db.close()


async def _run_check(job: BackgroundJob) -> None:
    # Snapshot id+url off the event loop and close the session immediately.
    rows = await asyncio.to_thread(_load_rows)

    async with job.lock:
        job.state["total"] = len(rows)

    results: list[tuple[str, bool]] = []
    queue: asyncio.Queue[tuple[str, str] | None] = asyncio.Queue(
        maxsize=CONCURRENCY * 2
    )

    async with httpx.AsyncClient(
        headers={"User-Agent": "Gyrus/1.0 LinkCheck"},
        event_hooks={"request": [strict_public_request_guard]},
    ) as client:
        async def worker() -> None:
            while True:
                item = await queue.get()
                try:
                    if item is None:
                        return
                    bm_id, url = item
                    if job.cancelled:
                        continue
                    try:
                        outcome = await _check_url(client, url)
                    except Exception:
                        logger.exception("Unexpected link-check failure for %s", url)
                        outcome = None
                    if outcome is not None:
                        results.append((bm_id, outcome))
                    async with job.lock:
                        job.state["checked"] += 1
                        if outcome is True:
                            job.state["dead_found"] += 1
                finally:
                    queue.task_done()

        workers = [asyncio.create_task(worker()) for _ in range(CONCURRENCY)]
        was_cancelled = False
        try:
            for row in rows:
                if job.cancelled:
                    break
                await queue.put(row)
            await queue.join()
        except asyncio.CancelledError:
            was_cancelled = True
        finally:
            if was_cancelled:
                for worker_task in workers:
                    worker_task.cancel()
            else:
                for _ in workers:
                    await queue.put(None)
            await asyncio.gather(*workers, return_exceptions=True)

    # Keep completed work even if the user stopped the remaining checks.
    await asyncio.to_thread(_persist_results, results)


async def start() -> dict:
    total = await asyncio.to_thread(_bookmark_count)
    # Pre-load total so the UI shows a real number immediately.
    return await job.start(_run_check, reset={"total": total})
