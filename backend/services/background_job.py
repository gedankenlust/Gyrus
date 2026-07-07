"""
Shared scaffold for one-at-a-time background jobs with pollable progress.

Link check, metadata refresh and batch auto-tagging all follow the same
lifecycle: start once, poll a status dict, optionally cancel mid-run. Before
this module each service hand-rolled the state dict / task / cancel plumbing,
and each copy grew its own bugs (e.g. a cancel() that didn't abort in-flight
work). The scaffold owns the lifecycle; services only provide the runner.

Usage:
    job = BackgroundJob(checked=0, total=0, dead_found=0)

    async def _run(job: BackgroundJob) -> None:
        ...
        job.state["checked"] += 1          # plain assignment, GIL-atomic
        if job.cancelled: return           # cooperative early-exit
        ...

    async def start() -> dict:
        return await job.start(_run, reset={"total": precomputed_total})

The runner may also raise asyncio.CancelledError naturally (job.cancel()
cancels the task, which aborts in-flight awaits like HTTP calls); the wrapper
swallows it and finalizes state either way.
"""
import asyncio
from datetime import datetime, timezone
from typing import Any, Awaitable, Callable


def _now() -> str:
    return datetime.now(timezone.utc).isoformat()


class BackgroundJob:
    def __init__(self, **progress_fields: Any):
        # Initial values double as the reset values for each new run.
        self._initial = {
            "running": False,
            "started_at": None,
            "finished_at": None,
            "error": None,
            **progress_fields,
        }
        self.state: dict = dict(self._initial)
        self.lock = asyncio.Lock()
        self._task: asyncio.Task | None = None
        self._cancelled = False

    # -- Introspection ---------------------------------------------------

    @property
    def cancelled(self) -> bool:
        return self._cancelled

    def get_status(self) -> dict:
        return dict(self.state)

    def is_running(self) -> bool:
        return bool(self.state["running"])

    # -- Lifecycle ---------------------------------------------------------

    def cancel(self) -> dict:
        """Stop the running job now; work already committed is kept.

        Sets the cooperative flag AND cancels the task — the flag alone would
        only prevent new work from starting while in-flight awaits (HTTP
        calls, LLM requests) kept running, which made "Stop" feel dead."""
        if self.state["running"]:
            self._cancelled = True
            if self._task and not self._task.done():
                self._task.cancel()
        return self.get_status()

    async def start(
        self,
        runner: Callable[["BackgroundJob"], Awaitable[None]],
        reset: dict | None = None,
    ) -> dict:
        """Start `runner` unless a run is already active (then: no-op).
        Progress fields are reset to their initial values, then `reset` is
        applied on top (e.g. a precomputed total so the UI shows a real
        number immediately)."""
        if self.state["running"]:
            return self.get_status()
        self._cancelled = False

        async with self.lock:
            self.state.update(self._initial)
            if reset:
                self.state.update(reset)
            self.state["running"] = True
            self.state["started_at"] = _now()
            self.state["finished_at"] = None

        self._task = asyncio.create_task(self._wrap(runner))
        return self.get_status()

    async def run_noop(self, reset: dict | None = None) -> dict:
        """Record a completed no-op run without spawning a task — the caller
        knows there is nothing to do (e.g. an empty id list) and the poller
        should see a finished run immediately, not a brief 'running' blip."""
        if self.state["running"]:
            return self.get_status()
        async with self.lock:
            self.state.update(self._initial)
            if reset:
                self.state.update(reset)
            now = _now()
            self.state["started_at"] = now
            self.state["finished_at"] = now
        return self.get_status()

    async def _wrap(self, runner: Callable[["BackgroundJob"], Awaitable[None]]) -> None:
        try:
            await runner(self)
        except asyncio.CancelledError:
            pass  # cancel() aborted in-flight work; fall through to finalize
        except Exception as e:  # a crashed job must never look "running" forever
            self.state["error"] = str(e)
        finally:
            # Plain assignments (no await): during cancellation, awaiting the
            # lock could re-raise CancelledError before we record completion.
            self.state["running"] = False
            self.state["finished_at"] = _now()
