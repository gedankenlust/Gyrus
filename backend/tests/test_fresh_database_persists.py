"""A fresh database must keep what is written after the migrations ran.

The embeddings migration once closed a connection from a second SQLite
library (apsw) inside the process. That close deleted the -wal and -shm files
the app's own connections were still using. Those connections went on
writing into the deleted log, and when the backend was stopped without closing
them, every later write, including the migrations' own version stamps, was
gone at the next start.
"""
import os
import sqlite3
import subprocess
import sys
from pathlib import Path

from alembic.config import Config
from alembic.script import ScriptDirectory

BACKEND = Path(__file__).parents[1]

# The real startup (backups, migrations, resumed work) through the app's
# lifespan, one write through the API, then an exit without closing anything,
# as when the app quits and stops the backend. A clean close would checkpoint
# the orphaned log and hide the bug.
STARTUP = """
import os
from fastapi.testclient import TestClient
import main

with TestClient(main.app, headers={"X-Gyrus-Token": main.API_TOKEN}) as client:
    response = client.post("/api/collections", json={"name": "Written after startup"})
    assert response.status_code == 201, response.text
    os._exit(0)
"""


def test_writes_after_migrating_a_fresh_database_survive_a_restart(tmp_path):
    # A separate process, like a real start: the bug lived in process-wide
    # SQLite state and only showed once that process was gone.
    subprocess.run(
        [sys.executable, "-c", STARTUP],
        cwd=BACKEND,
        env={**os.environ, "GYRUS_DATA_DIR": str(tmp_path), "GYRUS_API_TOKEN": "test-token"},
        check=True,
        timeout=120,
    )

    config = Config(str(BACKEND / "alembic.ini"))
    config.set_main_option("script_location", str(BACKEND / "alembic"))
    head = ScriptDirectory.from_config(config).get_current_head()
    connection = sqlite3.connect(tmp_path / "db" / "gyrus.db")
    try:
        assert connection.execute("SELECT version_num FROM alembic_version").fetchone() == (head,)
        assert connection.execute("SELECT name FROM collections").fetchall() == [("Written after startup",)]
    finally:
        connection.close()
