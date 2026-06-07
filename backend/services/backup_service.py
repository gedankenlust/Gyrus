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


def run_daily_backup() -> None:
    """Write a DB snapshot if the newest one is older than MIN_INTERVAL."""
    try:
        if not DB_PATH.exists():
            return
        BACKUP_DIR.mkdir(parents=True, exist_ok=True)

        existing = sorted(BACKUP_DIR.glob("gyrus-*.db"))
        if existing:
            age = datetime.now() - datetime.fromtimestamp(existing[-1].stat().st_mtime)
            if age < MIN_INTERVAL:
                return

        dst = BACKUP_DIR / f"gyrus-{datetime.now():%Y%m%d-%H%M%S}.db"
        _snapshot(DB_PATH, dst)
        logger.info("DB backup written: %s", dst.name)

        # Keep only the most recent KEEP snapshots.
        for old in sorted(BACKUP_DIR.glob("gyrus-*.db"))[:-KEEP]:
            old.unlink(missing_ok=True)
    except Exception as e:
        logger.warning("DB backup failed: %s", e)


def _snapshot(src_path: Path, dst_path: Path) -> None:
    """Consistent online copy via SQLite's backup API (safe under WAL)."""
    src = sqlite3.connect(src_path)
    try:
        dst = sqlite3.connect(dst_path)
        try:
            src.backup(dst)
        finally:
            dst.close()
    finally:
        src.close()
