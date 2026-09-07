"""Loop-safe fire-and-forget scheduling for background coroutines.

Two problems this solves:

1. Bare ``asyncio.create_task(...)`` results were discarded — the event loop
   only keeps a weak reference to tasks, so a discarded task can in theory be
   garbage-collected mid-flight.  We keep strong references until done.

2. Sync route handlers (``def`` endpoints) run in a worker thread where there
   is no running event loop, so ``create_task`` raises.  We capture the main
   loop at app startup and hand coroutines over via
   ``run_coroutine_threadsafe`` in that case.
"""
import asyncio
import logging
import threading

logger = logging.getLogger(__name__)

_bg_tasks: set = set()
_tasks_lock = threading.RLock()


def track(task):
    with _tasks_lock:
        _bg_tasks.add(task)
    def finished(done):
        with _tasks_lock:
            _bg_tasks.discard(done)
        if not done.cancelled():
            error = done.exception()
            if error is not None:
                logger.error("Background operation failed: %s", error)
    task.add_done_callback(finished)
    return task


def is_busy() -> bool:
    with _tasks_lock:
        return any(not task.done() for task in _bg_tasks)

_main_loop: asyncio.AbstractEventLoop | None = None


def capture_loop() -> None:
    """Remember the running event loop. Call once from the app's lifespan."""
    global _main_loop
    _main_loop = asyncio.get_running_loop()


def schedule(coro) -> None:
    """Run *coro* in the background, from any thread. Never raises."""
    try:
        loop = asyncio.get_running_loop()
    except RuntimeError:
        loop = _main_loop
        if loop is None or loop.is_closed():
            coro.close()
            logger.debug("background.schedule dropped %r — no event loop", coro)
            return
        track(asyncio.run_coroutine_threadsafe(coro, loop))
        return
    task = loop.create_task(coro)
    track(task)


async def drain() -> None:
    """Await all currently pending background tasks (used by tests)."""
    with _tasks_lock:
        pending = [t if isinstance(t, asyncio.Future) else asyncio.wrap_future(t) for t in _bg_tasks if not t.done()]
    if pending:
        await asyncio.gather(*pending, return_exceptions=True)
