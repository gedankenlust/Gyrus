"""Process-local opt-in, supplied by the native app after every backend start."""
from fastapi import HTTPException

_enabled = False
_generation = 0


def enabled() -> bool:
    return _enabled


def generation() -> int:
    return _generation


def configure(value: bool) -> None:
    global _enabled, _generation
    if value != _enabled:
        _generation += 1
    _enabled = value


def require_ai() -> None:
    if not _enabled:
        raise HTTPException(503, "AI is disabled. Enable AI in Settings to use this feature.")


def invalidate_requests():
    global _generation
    _generation += 1
