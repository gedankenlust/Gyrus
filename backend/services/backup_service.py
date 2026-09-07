"""Daily snapshot of the SQLite database.

A local-first app has no cloud safety net, so the database is the single
point of failure. On startup this writes a consistent copy once a day and
keeps the most recent few, so an accidental bulk delete or a bad migration
is always recoverable.
"""
import logging
import sqlite3
import os
import tempfile
import threading

backup_lock = threading.RLock()
_last_error = None
from datetime import datetime, timedelta
from pathlib import Path

from database import DATA_DIR, DB_PATH

logger = logging.getLogger(__name__)

BACKUP_DIR = DATA_DIR / "db" / "backups"
KEEP = 7
MIN_INTERVAL = timedelta(hours=20)

# Daily snapshots are named with a leading date digit; pre-migration ones carry
# a distinct prefix so the two rings prune independently.
DAILY_GLOB = "gyrus-[0-9]*.db"
PREMIGRATION_GLOB = "gyrus-premigration-*.db"
KEEP_PREMIGRATION = 3


def run_daily_backup() -> None:
    """Write a DB snapshot if the newest daily one is older than MIN_INTERVAL."""
    global _last_error
    try:
        if not DB_PATH.exists():
            return
        BACKUP_DIR.mkdir(parents=True, exist_ok=True)

        existing = sorted(BACKUP_DIR.glob(DAILY_GLOB))
        if existing:
            age = datetime.now() - datetime.fromtimestamp(existing[-1].stat().st_mtime)
            if age < MIN_INTERVAL:
                return

        dst = BACKUP_DIR / f"gyrus-{datetime.now():%Y%m%d-%H%M%S}.db"
        _snapshot(DB_PATH, dst)
        _last_error = None
        logger.info("DB backup written: %s", dst.name)

        # Keep only the most recent KEEP daily snapshots.
        for old in sorted(BACKUP_DIR.glob(DAILY_GLOB))[:-KEEP]:
            old.unlink(missing_ok=True)
    except Exception as e:
        _last_error = str(e)
        logger.warning("DB backup failed: %s", e)


def backup_before_migration() -> None:
    """Snapshot taken right before a schema migration runs.

    Unlike :func:`run_daily_backup`, this ignores the daily throttle — a schema
    change must ALWAYS be preceded by a fresh, recoverable copy, even if a daily
    backup already happened earlier today. Kept in a separate small ring.
    """
    try:
        if not DB_PATH.exists():
            return
        BACKUP_DIR.mkdir(parents=True, exist_ok=True)

        # Microseconds keep the name unique even if two migrations run in the
        # same second (and lets tests snapshot in a tight loop).
        dst = BACKUP_DIR / f"gyrus-premigration-{datetime.now():%Y%m%d-%H%M%S-%f}.db"
        _snapshot(DB_PATH, dst)
        logger.info("Pre-migration DB backup written: %s", dst.name)

        for old in sorted(BACKUP_DIR.glob(PREMIGRATION_GLOB))[:-KEEP_PREMIGRATION]:
            old.unlink(missing_ok=True)
    except Exception as e:
        logger.warning("Pre-migration backup failed: %s", e)


def _snapshot(src_path: Path, dst_path: Path) -> None:
    """Consistent online copy via SQLite's backup API (safe under WAL)."""
    fd, temporary = tempfile.mkstemp(dir=dst_path.parent, prefix='.snapshot-')
    os.close(fd)
    try:
        src = sqlite3.connect(src_path)
        try:
            dst = sqlite3.connect(temporary)
            try:
                src.backup(dst)
            finally:
                dst.close()
        finally:
            src.close()
        os.replace(temporary, dst_path)
    finally:
        Path(temporary).unlink(missing_ok=True)


def save_before_restore(content: bytes) -> Path:
    """Keep a small separate ring of portable backups; fail before replacement."""
    BACKUP_DIR.mkdir(parents=True, exist_ok=True, mode=0o700)
    destination = BACKUP_DIR / f"gyrus-prerestore-{datetime.now():%Y%m%d-%H%M%S-%f}.json"
    fd, temporary = tempfile.mkstemp(dir=BACKUP_DIR, prefix='.restore-')
    try:
        with os.fdopen(fd, 'wb') as file:
            file.write(content)
            file.flush()
            os.fsync(file.fileno())
        os.replace(temporary, destination)
    finally:
        Path(temporary).unlink(missing_ok=True)
    for old in sorted(BACKUP_DIR.glob('gyrus-prerestore-*.json'))[:-3]:
        old.unlink(missing_ok=True)
    return destination


def backup_status():
    copies = sorted(BACKUP_DIR.glob(DAILY_GLOB)) if BACKUP_DIR.exists() else []
    return {'error': _last_error, 'last_backup_at': datetime.fromtimestamp(copies[-1].stat().st_mtime).astimezone().isoformat() if copies else None}


# Snapshot writers and factory-reset pruning must not overlap. The lock lives
# here so every caller uses the same ordering for generated safety copies.
def _locked(function):
    from functools import wraps
    @wraps(function)
    def call(*args, **kwargs):
        with backup_lock:
            return function(*args, **kwargs)
    return call

run_daily_backup = _locked(run_daily_backup)
backup_before_migration = _locked(backup_before_migration)
save_before_restore = _locked(save_before_restore)
backup_status = _locked(backup_status)
