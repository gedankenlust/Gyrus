"""Stop the backend when the Mac app that launched it is gone.

If the app crashes or is force-quit, nothing else terminates the uvicorn child.
An orphaned backend keeps port 8080 and the SQLite file busy, so the next app
launch finds a stale server it did not start. The app passes its pid in
GYRUS_PARENT_PID; this module polls it and shuts the server down cleanly.
"""
from __future__ import annotations

import logging
import os
import signal
import threading
import time
from typing import Callable

logger = logging.getLogger(__name__)

PARENT_PID_ENV = "GYRUS_PARENT_PID"
CHECK_INTERVAL_SECONDS = 2.0
# Time uvicorn gets to finish in-flight requests and lifespan shutdown after
# SIGTERM before the process is ended forcibly.
SHUTDOWN_GRACE_SECONDS = 10.0


def parent_pid_from_env(environ: dict[str, str] | None = None) -> int | None:
    value = (environ if environ is not None else os.environ).get(PARENT_PID_ENV, "").strip()
    if not value:
        return None
    try:
        pid = int(value)
    except ValueError:
        logger.warning("Ignoring invalid %s=%r", PARENT_PID_ENV, value)
        return None
    # pid 0/1 would mean "process group" or launchd — never a real parent app.
    return pid if pid > 1 else None


def parent_alive(pid: int, *, was_direct_parent: bool = False) -> bool:
    """Return whether the watched process still exists.

    When the app spawned us directly, a changed getppid() is authoritative: we
    were re-parented to launchd, even if the old pid was already reused.
    """
    if was_direct_parent and os.getppid() != pid:
        return False
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        # The pid exists but belongs to someone else (possible after reuse);
        # without the getppid signal we cannot tell, so stay up.
        return True
    except OSError:
        return False
    return True


def _terminate_self() -> None:
    # SIGTERM lets uvicorn run its normal graceful shutdown (lifespan exit,
    # open connections drained). If that does not finish in time, exit hard.
    try:
        os.kill(os.getpid(), signal.SIGTERM)
    except OSError:
        logger.exception("Could not signal backend shutdown")
    time.sleep(SHUTDOWN_GRACE_SECONDS)
    os._exit(0)


def watch_parent(
    pid: int,
    *,
    interval: float = CHECK_INTERVAL_SECONDS,
    stop: threading.Event | None = None,
    on_parent_exit: Callable[[], None] = _terminate_self,
    is_alive: Callable[..., bool] = parent_alive,
) -> None:
    """Block until the parent disappears (then call on_parent_exit) or stop is set."""
    stop = stop or threading.Event()
    was_direct_parent = os.getppid() == pid
    while not stop.wait(interval):
        if not is_alive(pid, was_direct_parent=was_direct_parent):
            logger.warning("Parent process %d is gone; shutting the backend down", pid)
            on_parent_exit()
            return


def start_parent_watchdog(environ: dict[str, str] | None = None) -> threading.Event | None:
    """Start the daemon watcher when GYRUS_PARENT_PID is set; no-op otherwise.

    Returns an Event that stops the watcher, or None when nothing was started.
    """
    pid = parent_pid_from_env(environ)
    if pid is None:
        return None
    stop = threading.Event()
    thread = threading.Thread(
        target=watch_parent,
        args=(pid,),
        kwargs={"stop": stop},
        name="gyrus-parent-watchdog",
        daemon=True,
    )
    thread.start()
    return stop
