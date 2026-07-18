import os
from pathlib import Path
from sqlalchemy import create_engine, event
from sqlalchemy.orm import DeclarativeBase, sessionmaker

DATA_DIR = Path(os.environ.get("GYRUS_DATA_DIR", Path.home() / ".gyrus")).expanduser()
DATA_DIR.mkdir(parents=True, exist_ok=True, mode=0o700)
for directory in (DATA_DIR, DATA_DIR / "favicons", DATA_DIR / "og_images", DATA_DIR / "db"):
    directory.mkdir(exist_ok=True, mode=0o700)
    directory.chmod(0o700)

DB_PATH = DATA_DIR / "db" / "gyrus.db"
DATABASE_URL = f"sqlite:///{DB_PATH}"

engine = create_engine(
    DATABASE_URL,
    connect_args={"check_same_thread": False},
)


@event.listens_for(engine, "connect")
def set_sqlite_pragma(dbapi_connection, _):
    if DB_PATH.exists():
        DB_PATH.chmod(0o600)
    cursor = dbapi_connection.cursor()
    cursor.execute("PRAGMA journal_mode=WAL")
    cursor.execute("PRAGMA foreign_keys=ON")
    cursor.close()


SessionLocal = sessionmaker(autocommit=False, autoflush=False, bind=engine)


class Base(DeclarativeBase):
    pass


def get_db():
    db = SessionLocal()
    try:
        yield db
    finally:
        db.close()
