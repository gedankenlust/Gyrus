"""Interruptible rest periods for local taxonomy requests (not a GPU power cap)."""
from asyncio import sleep
import math
from time import monotonic


class TaggingPacer:
    def __init__(self, enabled: bool, progress=None):
        self.enabled = enabled
        self.progress = progress

    async def rest(self, work_seconds: float, phase: str):
        if not self.enabled:
            return
        # Roughly one second of rest per second spent on the preceding request.
        # Even very fast batches get a short break. Long rests remain cancellable.
        duration = min(180.0, max(2.0, work_seconds))
        deadline = monotonic() + duration
        while (remaining := deadline - monotonic()) > 0:
            if self.progress:
                self.progress('cooldown', math.ceil(remaining))
            await sleep(min(1.0, remaining))
        if self.progress:
            self.progress(phase, 0)
