"""Daily snapshot of the SQLite database.

A local-first app has no cloud safety net, so the database is the single
point of failure. On startup this writes a consistent copy once a day and
keeps the most recent few, so an accidental bulk delete or a bad migration
is always recoverable.
"""
import logging
import sqlite3
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
        logger.info("DB backup written: %s", dst.name)

        # Keep only the most recent KEEP daily snapshots.
        for old in sorted(BACKUP_DIR.glob(DAILY_GLOB))[:-KEEP]:
            old.unlink(missing_ok=True)
    except Exception as e:
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
    src = sqlite3.connect(src_path)
    try:
        dst = sqlite3.connect(dst_path)
        try:
            src.backup(dst)
        finally:
            dst.close()
        dst_path.chmod(0o600)
    finally:
        src.close()
