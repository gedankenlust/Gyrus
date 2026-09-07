"""Exclude library replacement / URL edits from in-flight writers and jobs.

The ASGI lifetime includes streamed replies and response background tasks.
An operation is refused before changing data when the library is busy.
"""
import threading
from contextvars import ContextVar
from fastapi import HTTPException
from starlette.responses import JSONResponse

_lock = threading.RLock()
_requests: set[object] = set()
_owner = None
_request = ContextVar("gyrus_request", default=None)
BUSY_MESSAGE = "Background work is still running. Wait for it to finish or stop it, then try again."


def reserve() -> None:
    global _owner
    from services import background
    ident = _request.get()
    with _lock:
        if _owner is not None and _owner is not ident:
            raise HTTPException(409, BUSY_MESSAGE)
        if _requests - {ident} or background.is_busy():
            raise HTTPException(409, BUSY_MESSAGE)
        # Direct service calls without ASGI have no request lifetime to reserve.
        if ident is not None:
            _owner = ident


class MaintenanceMiddleware:
    def __init__(self, app):
        self.app = app

    async def __call__(self, scope, receive, send):
        global _owner
        path = scope.get("path", "")
        if scope["type"] != "http" or not path.startswith("/api/") or path.startswith("/api/files/"):
            return await self.app(scope, receive, send)
        ident = object()
        with _lock:
            blocked = _owner is not None
            if not blocked:
                _requests.add(ident)
        if blocked:
            return await JSONResponse({"detail": "Library maintenance is in progress. Please try again."}, status_code=409)(scope, receive, send)
        token = _request.set(ident)
        try:
            await self.app(scope, receive, send)
        finally:
            with _lock:
                _requests.discard(ident)
                if _owner is ident:
                    _owner = None
            _request.reset(token)
