import pytest
from contextlib import asynccontextmanager
from fastapi import FastAPI
from fastapi.testclient import TestClient
from sqlalchemy import create_engine, event
from sqlalchemy.orm import sessionmaker
from sqlalchemy.pool import StaticPool
from database import Base, get_db
import models  # noqa: F401 — registers Bookmark, Collection, Tag, BookmarkTag with Base
from routers import bookmarks, collections, tags, search, import_, export_, files, brain, data


@asynccontextmanager
async def _no_op_lifespan(app):
    yield


_test_app = FastAPI(lifespan=_no_op_lifespan)
for router in [bookmarks.router, collections.router, tags.router,
               search.router, import_.router, export_.router, files.router, brain.router, data.router]:
    _test_app.include_router(router)


@_test_app.get("/health")
def health():
    return {"status": "ok"}


@pytest.fixture
def engine():
    engine = create_engine(
        "sqlite:///:memory:",
        connect_args={"check_same_thread": False},
        poolclass=StaticPool,
    )

    @event.listens_for(engine, "connect")
    def set_pragmas(conn, _):
        cur = conn.cursor()
        cur.execute("PRAGMA foreign_keys=ON")
        cur.close()

    Base.metadata.create_all(engine)
    return engine


@pytest.fixture
def db(engine):
    Session = sessionmaker(bind=engine)
    db = Session()
    try:
        yield db
    finally:
        db.close()


@pytest.fixture
def client(engine, db):
    def override():
        yield db

    _test_app.dependency_overrides[get_db] = override
    with TestClient(_test_app) as c:
        yield c
    _test_app.dependency_overrides.clear()
