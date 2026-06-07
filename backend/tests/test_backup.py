"""Tests for the daily database backup."""
import sqlite3
from datetime import timedelta
from pathlib import Path

import pytest

from services import backup_service


def _make_db(path: Path) -> None:
    con = sqlite3.connect(path)
    con.execute("CREATE TABLE t (id INTEGER)")
    con.execute("INSERT INTO t VALUES (1)")
    con.commit()
    con.close()


@pytest.fixture
def tmp_backup(tmp_path, monkeypatch):
    db = tmp_path / "gyrus.db"
    _make_db(db)
    backups = tmp_path / "backups"
    monkeypatch.setattr(backup_service, "DB_PATH", db)
    monkeypatch.setattr(backup_service, "BACKUP_DIR", backups)
    return db, backups


def test_writes_a_valid_snapshot(tmp_backup):
    _, backups = tmp_backup
    backup_service.run_daily_backup()
    snaps = list(backups.glob("gyrus-*.db"))
    assert len(snaps) == 1
    con = sqlite3.connect(snaps[0])
    assert con.execute("SELECT COUNT(*) FROM t").fetchone()[0] == 1
    con.close()


def test_skips_when_a_recent_backup_exists(tmp_backup):
    _, backups = tmp_backup
    backup_service.run_daily_backup()
    backup_service.run_daily_backup()  # immediately again
    assert len(list(backups.glob("gyrus-*.db"))) == 1


def test_no_db_no_backup(tmp_path, monkeypatch):
    monkeypatch.setattr(backup_service, "DB_PATH", tmp_path / "missing.db")
    monkeypatch.setattr(backup_service, "BACKUP_DIR", tmp_path / "backups")
    backup_service.run_daily_backup()
    assert not (tmp_path / "backups").exists() or not list((tmp_path / "backups").glob("*"))


def test_prunes_to_keep_limit(tmp_backup, monkeypatch):
    _, backups = tmp_backup
    monkeypatch.setattr(backup_service, "MIN_INTERVAL", timedelta(0))
    monkeypatch.setattr(backup_service, "KEEP", 3)
    backups.mkdir(parents=True, exist_ok=True)
    for i in range(5):
        (backups / f"gyrus-2026010{i}-000000.db").write_bytes(b"old")
    backup_service.run_daily_backup()
    assert len(list(backups.glob("gyrus-*.db"))) == 3
