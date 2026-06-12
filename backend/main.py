from contextlib import asynccontextmanager
from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from routers import bookmarks, collections, tags, search, import_, export_, files, brain, data


@asynccontextmanager
async def lifespan(app: FastAPI):
    # Let sync route handlers (worker threads) hand coroutines to this loop.
    from services import background
    background.capture_loop()
    # Snapshot the database before migrations touch the schema, so a bad
    # migration or an accidental bulk delete is always recoverable.
    from services.backup_service import run_daily_backup
    run_daily_backup()
    # Ensure the database schema is up to date before serving requests.
    # Covers fresh installs and pulling a version with new migrations.
    from alembic.config import Config
    from alembic import command
    command.upgrade(Config("alembic.ini"), "head")
    # Permanently remove bookmarks that have sat in the Trash past the
    # retention window (best-effort — must never block startup).
    try:
        from database import SessionLocal
        from services import bookmark_service
        db = SessionLocal()
        try:
            bookmark_service.purge_expired(db)
        finally:
            db.close()
    except Exception:
        pass
    yield


app = FastAPI(title="Gyrus API", version="0.1.0", lifespan=lifespan)

app.add_middleware(
    CORSMiddleware,
    allow_origin_regex=r"^(chrome-extension|moz-extension|safari-web-extension)://.*",
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

app.include_router(bookmarks.router)
app.include_router(collections.router)
app.include_router(tags.router)
app.include_router(search.router)
app.include_router(import_.router)
app.include_router(export_.router)
app.include_router(files.router)
app.include_router(brain.router)
app.include_router(data.router)


@app.get("/health")
def health():
    return {"status": "ok", "version": "0.1.0"}
