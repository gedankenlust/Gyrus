"""
Dead-link detection.

Runs as a background asyncio task; stores progress in a module-level dict
so the API can poll it. One run at a time — if already running, /start is a no-op.
"""
import asyncio
import ipaddress
import httpx
from urllib.parse import urlparse
from database import SessionLocal
from models.bookmark import Bookmark
from services.background_job import BackgroundJob
from services.outbound_url_security import strict_public_request_guard


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


async def _check_url(client: httpx.AsyncClient, url: str) -> bool:
    """Returns True only when the URL is reliably dead.

    Dead means a definitive 404/410, or a connection failure (DNS /
    refused) that persists across every retry. Timeouts and other
    transient network errors are retried and never mark a link dead on
    their own — a slow or briefly unreachable server is not a dead link.
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
        except httpx.ConnectError:
            # DNS failure / connection refused — can be transient under load.
            # Retry; only count as dead if it never connects.
            if attempt == RETRIES - 1:
                return True
            await asyncio.sleep(RETRY_DELAY)
        except httpx.RequestError:
            # Timeout or other transient network error — retry, but never
            # mark dead on this alone. A slow server is not a dead link.
            if attempt == RETRIES - 1:
                return False
            await asyncio.sleep(RETRY_DELAY)
    return False


async def _run_check(job: BackgroundJob) -> None:
    # 1) Snapshot id+url once (avoids session-lifetime issues during long check)
    db = SessionLocal()
    try:
        rows = [(b.id, b.url) for b in db.query(Bookmark).all()]
    finally:
        db.close()

    async with job.lock:
        job.state["total"] = len(rows)

    results: list[tuple[str, bool]] = []  # (bookmark_id, is_dead)
    sem = asyncio.Semaphore(CONCURRENCY)

    async with httpx.AsyncClient(
        headers={"User-Agent": "Gyrus/1.0 LinkCheck"},
        event_hooks={"request": [strict_public_request_guard]},
    ) as client:
        async def check_one(bm_id: str, url: str) -> None:
            if job.cancelled:
                return
            async with sem:
                if job.cancelled:
                    return
                is_dead = await _check_url(client, url)
            results.append((bm_id, is_dead))
            async with job.lock:
                job.state["checked"] += 1
                if is_dead:
                    job.state["dead_found"] += 1

        tasks = [asyncio.create_task(check_one(i, u)) for i, u in rows]
        try:
            await asyncio.gather(*tasks, return_exceptions=True)
        except asyncio.CancelledError:
            pass  # cancelled mid-run: still commit what finished

    # 2) Batch-commit all results at the end (single short DB transaction;
    # synchronous, so it completes even after a swallowed cancellation)
    db = SessionLocal()
    try:
        for bm_id, is_dead in results:
            bm = db.query(Bookmark).filter(Bookmark.id == bm_id).first()
            if bm is not None and bm.is_dead != is_dead:
                bm.is_dead = is_dead
        db.commit()
    finally:
        db.close()


async def start() -> dict:
    db = SessionLocal()
    try:
        total = db.query(Bookmark).count()
    finally:
        db.close()
    # Pre-load total so the UI shows a real number immediately.
    return await job.start(_run_check, reset={"total": total})
