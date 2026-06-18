import re
from contextlib import asynccontextmanager
from fastapi import FastAPI, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse
from routers import bookmarks, collections, tags, search, import_, export_, files, brain, data

# The only legitimate cross-origin caller is the browser extension. The native
# app sends no Origin header at all.
_ALLOWED_ORIGIN = re.compile(r"^(chrome-extension|moz-extension|safari-web-extension)://")


@asynccontextmanager
async def lifespan(app: FastAPI):
    # Let sync route handlers (worker threads) hand coroutines to this loop.
    from services import background
    background.capture_loop()
    # Ensure the database schema is up to date before serving requests.
    # Covers fresh installs and pulling a version with new migrations.
    from alembic.config import Config
    from alembic import command
    from services.backup_service import run_daily_backup, backup_before_migration
    from database import DB_PATH
    cfg = Config("alembic.ini")

    # Was there an existing database before we touched it? (engine.connect()
    # below would create an empty file, so capture this first.)
    db_existed = DB_PATH.exists()

    # Take a guaranteed snapshot right before the schema actually changes on an
    # EXISTING database, regardless of the daily throttle — so a bad migration
    # is never unrecoverable. Fresh installs have nothing to protect. Detection
    # must never block startup.
    try:
        from alembic.script import ScriptDirectory
        from alembic.runtime.migration import MigrationContext
        from database import engine
        script = ScriptDirectory.from_config(cfg)
        with engine.connect() as conn:
            current = MigrationContext.configure(conn).get_current_revision()
        if db_existed and current != script.get_current_head():
            backup_before_migration()
    except Exception:
        pass

    # Routine daily safety net (independent of migrations).
    run_daily_backup()
    command.upgrade(cfg, "head")
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


@app.middleware("http")
async def block_cross_site_origin(request: Request, call_next):
    """Reject requests from web pages — a localhost CSRF guard.

    CORS stops a malicious site from *reading* our responses, but not from
    firing state-changing "simple" requests (no preflight) at the backend
    running on 127.0.0.1 — e.g. a one-line `fetch()` to /api/data/factory-reset
    could wipe everything. CORS can't prevent the side effect; we must.

    Allowed callers: the browser extension (Origin chrome/moz/safari-extension)
    and the native app (no Origin header). Any http(s) web Origin is blocked.
    """
    origin = request.headers.get("origin")
    if origin and not _ALLOWED_ORIGIN.match(origin):
        return JSONResponse(status_code=403, content={"detail": "Cross-site request blocked"})
    return await call_next(request)


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
