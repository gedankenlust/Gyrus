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

logger = logging.getLogger(__name__)

_bg_tasks: set = set()
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
        asyncio.run_coroutine_threadsafe(coro, loop)
        return
    task = loop.create_task(coro)
    _bg_tasks.add(task)
    task.add_done_callback(_bg_tasks.discard)


async def drain() -> None:
    """Await all currently pending background tasks (used by tests)."""
    pending = [t for t in _bg_tasks if not t.done()]
    if pending:
        await asyncio.gather(*pending, return_exceptions=True)
