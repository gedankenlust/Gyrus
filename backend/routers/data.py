import shutil
import logging
from fastapi import APIRouter, Depends, HTTPException
from fastapi.responses import JSONResponse
from sqlalchemy.orm import Session
from database import get_db, DATA_DIR
from services import bookmark_service, ai_policy, json_backup_service
from services.brain_sync_service import brain_sync_service
from services.json_backup_service import RestoreData, SUPPORTED_BACKUP_VERSIONS
from models.bookmark import Bookmark, BookmarkNote, BrainMessage
from models.collection import Collection
from models.tag import Tag, BookmarkTag

router = APIRouter(prefix="/api/data", tags=["data"])
logger = logging.getLogger(__name__)

# Generated data that belongs to Gyrus and can safely be removed during a
# factory reset. The database itself stays open; clear_bookmarks() removes its
# rows while the internal backup copies are deleted here.
FACTORY_RESET_DIRECTORIES = (
    DATA_DIR / "favicons",
    DATA_DIR / "og_images",
    DATA_DIR / "visual_snapshots",
    DATA_DIR / "site_structure",
    DATA_DIR / "taxonomy-checkpoints",
    DATA_DIR / "python-cache",
    DATA_DIR / "db" / "backups",
)


def _clear_directory(directory) -> None:
    if not directory.exists():
        return
    for item in directory.iterdir():
        if item.is_file() or item.is_symlink():
            item.unlink(missing_ok=True)
        elif item.is_dir():
            shutil.rmtree(item)

@router.post("/clear-cache")
def clear_cache():
    """Delete all files in ~/.gyrus/favicons and ~/.gyrus/og-images."""
    favicons_dir = DATA_DIR / "favicons"
    og_images_dir = DATA_DIR / "og_images"
    
    for directory in [favicons_dir, og_images_dir]:
        _clear_directory(directory)
    return {"status": "ok"}

@router.post("/clear-brain")
def clear_brain():
    """Call brain_sync_service.clear_all_files()."""
    try:
        brain_sync_service.clear_all_files()
    except ValueError as exc:
        # The configured folder is too broad to sweep (home, Documents, ...).
        logger.warning("Brain files not cleared: %s", exc)
        raise HTTPException(409, "The AI Brain folder is too broad to clear safely. Remove the files manually.") from exc
    return {"status": "ok"}

@router.post("/clear-bookmarks")
def clear_bookmarks(db: Session = Depends(get_db)):
    """Delete all rows from bookmarks, collections, tags, and bookmark_notes."""
    from services.maintenance import reserve
    reserve()
    try:
        bookmark_ids = [row.id for row in db.query(Bookmark.id).all()]
        # Order matters for foreign key constraints if they aren't ON DELETE CASCADE
        # In Gyrus, they seem to be set up well, but we can be explicit.
        from services import vector_store
        vector_store.invalidate_for_replacement(db)
        db.query(BookmarkTag).delete()
        db.query(BrainMessage).delete()
        db.query(BookmarkNote).delete()
        db.query(Bookmark).delete()
        db.query(Collection).delete()
        db.query(Tag).delete()
        db.commit()
        vector_store.clear()
        bookmark_service.delete_generated_artifacts(bookmark_ids)
        _clear_directory(DATA_DIR / "taxonomy-checkpoints")
    except Exception as e:
        db.rollback()
        logger.exception("Failed to clear bookmarks")
        raise HTTPException(status_code=500, detail="Could not clear bookmarks") from e
    return {"status": "ok"}

@router.post("/factory-reset")
def factory_reset(db: Session = Depends(get_db)):
    """Remove all Gyrus-owned user data and return to a fresh state."""
    # Decide about the Brain folder before anything is wiped. A refusal used to
    # surface as a 500 after the library was already gone, leaving a
    # half-reset state (settings, caches and backups untouched).
    try:
        brain_sync_service.clearable_root()
        brain_clearable = True
    except ValueError as exc:
        logger.warning("Factory reset leaves Brain files in place: %s", exc)
        brain_clearable = False
    clear_bookmarks(db)
    brain_cleared = False
    if brain_clearable:
        try:
            brain_sync_service.clear_all_files()
            brain_cleared = True
        except (OSError, ValueError):
            logger.exception("Factory reset could not remove all Brain files")
    from services.backup_service import backup_lock
    with backup_lock:
        for directory in FACTORY_RESET_DIRECTORIES:
            try:
                _clear_directory(directory)
            except OSError:
                # Generated caches only; finishing the reset matters more.
                logger.exception("Factory reset could not clear %s", directory.name)
    from services import embedding_service
    ai_policy.configure(False)
    brain_sync_service.update_config(str(DATA_DIR / "brain"), False)
    embedding_service.set_active_model(embedding_service.DEFAULT_MODEL)
    embedding_service.set_active_base_url(embedding_service.DEFAULT_BASE_URL)
    # Additive field: false when the Brain folder was unsafe to sweep or some
    # files could not be removed, so the app can tell the user.
    return {"status": "ok", "brain_files_cleared": brain_cleared}


def _backup_response(db: Session) -> JSONResponse:
    return JSONResponse(
        content=json_backup_service.export_library(db),
        headers={"Content-Disposition": 'attachment; filename="gyrus_backup.json"'},
    )


@router.get("/backup")
def backup(db: Session = Depends(get_db)):
    """Export everything as a portable JSON backup."""
    return _backup_response(db)


@router.post("/restore/preview")
def preview_restore(data: RestoreData):
    return {
        "version": data.version,
        "exported_at": data.exported_at.isoformat() if data.exported_at else None,
        "collections": len(data.collections), "tags": len(data.tags),
        "bookmarks": len(data.bookmarks), "notes": len(data.bookmark_notes),
        "messages": len(data.brain_messages),
    }


@router.post("/restore")
def restore(data: RestoreData, db: Session = Depends(get_db)):
    """Replace ALL current data with the contents of a JSON backup."""
    if data.version not in SUPPORTED_BACKUP_VERSIONS:
        raise HTTPException(status_code=422, detail="Unsupported backup version")
    from services.maintenance import reserve
    reserve()
    # Store the exact old library before changing it. Failure aborts the
    # restore, rather than silently replacing the only remaining copy.
    from services.backup_service import save_before_restore
    try:
        save_before_restore(_backup_response(db).body)
    except OSError as exc:
        raise HTTPException(503, "Could not create a safety backup. No data was replaced.") from exc
    json_backup_service.restore_library(db, data)
    return {
        "status": "ok",
        "collections": len(data.collections),
        "tags": len(data.tags),
        "bookmarks": len(data.bookmarks),
    }


@router.get("/backup-status")
def automatic_backup_status():
    from services.backup_service import backup_status
    return backup_status()
