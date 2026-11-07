"""Library-wide background jobs under /api/bookmarks.

Link check, metadata refresh, batch auto-tagging (taxonomy drafts) and folder
organization each run one at a time on the event loop and are polled by the
app. Start routes stay `async def` because BackgroundJob.start must create its
task on the loop; status, cancel and draft routes do no loop work and run in
the threadpool (BackgroundJob.cancel is thread-safe).

This router has no prefix of its own: routers/bookmarks.py includes it before
its `/{bookmark_id}` routes, so these static paths are matched first.
"""
from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel
from sqlalchemy.orm import Session

from database import get_db
from services import ai_policy
from services import folder_organize_service
from services import link_check_service
from services import metadata_refresh_service
from services.localized_messages import localized

router = APIRouter()


def _auto_tag_batch_service():
    # Imported on use, as before the split: it pulls in the taxonomy stack,
    # which the rest of the bookmarks API must not depend on to load.
    from services import auto_tag_batch_service
    return auto_tag_batch_service


@router.post("/check-links")
async def start_link_check():
    return await link_check_service.start()


@router.get("/check-links/status")
def link_check_status():
    return link_check_service.get_status()


@router.post("/refresh-metadata")
async def start_metadata_refresh():
    return await metadata_refresh_service.start()


@router.get("/refresh-metadata/status")
def metadata_refresh_status():
    return metadata_refresh_service.get_status()


@router.post("/refresh-metadata/cancel")
def cancel_metadata_refresh():
    return metadata_refresh_service.cancel()


class AutoTagBatchRequest(BaseModel):
    bookmark_ids: list[str]
    provider_config: dict | None = {"provider": "ollama", "model": "llama3"}
    language: str | None = None


class TaxonomyTagEdit(BaseModel):
    id: str
    name: str
    enabled: bool = True


class ApplyTaxonomyRequest(BaseModel):
    draft_id: str
    tags: list[TaxonomyTagEdit]


@router.post("/auto-tag-batch", dependencies=[Depends(ai_policy.require_ai)])
async def start_auto_tag_batch(request: AutoTagBatchRequest):
    """Auto-tag a list of bookmarks in the background (one run at a time).
    Returns immediately with the initial status; poll /auto-tag-batch/status."""
    auto_tag_batch_service = _auto_tag_batch_service()
    unique_count = len(set(request.bookmark_ids))
    if unique_count < auto_tag_batch_service.MIN_TAXONOMY_BOOKMARKS:
        # A taxonomy needs shared categories (each backed by >= 2 bookmarks);
        # below this the clustering degenerates into singletons and the run is
        # guaranteed to fail after minutes of LLM work. Reject up front.
        detail = localized(
            "taxonomy_minimum",
            request.language == "de",
            minimum=auto_tag_batch_service.MIN_TAXONOMY_BOOKMARKS,
        )
        raise HTTPException(status_code=422, detail=detail)
    return await auto_tag_batch_service.start(request.bookmark_ids, request.provider_config, request.language)


@router.get("/auto-tag-batch/status")
def auto_tag_batch_status():
    return _auto_tag_batch_service().get_status()


@router.post("/auto-tag-batch/cancel")
def cancel_auto_tag_batch():
    return _auto_tag_batch_service().cancel()


@router.post("/auto-tag-batch/apply")
def apply_auto_tag_taxonomy(request: ApplyTaxonomyRequest, db: Session = Depends(get_db)):
    """Apply a reviewed taxonomy draft in one transaction."""
    from services import taxonomy_service
    return taxonomy_service.apply_draft(
        db,
        request.draft_id,
        [tag.model_dump() for tag in request.tags],
    )


@router.delete("/auto-tag-batch/draft/{draft_id}")
def discard_auto_tag_taxonomy(draft_id: str):
    _auto_tag_batch_service().discard_draft(draft_id)
    return {"status": "discarded"}


class OrganizeFoldersRequest(BaseModel):
    provider_config: dict | None = None
    language: str | None = None


class ApplyFoldersRequest(BaseModel):
    draft_id: str
    folder_keys: list[str] | None = None


@router.post("/organize-folders", dependencies=[Depends(ai_policy.require_ai)])
async def start_organize_folders(request: OrganizeFoldersRequest):
    """Let the local model build a new folder structure and move bookmarks into it."""
    return await folder_organize_service.start(request.provider_config, request.language)


@router.get("/organize-folders/status")
def organize_folders_status():
    return folder_organize_service.get_status()


@router.post("/organize-folders/cancel")
def cancel_organize_folders():
    return folder_organize_service.cancel()


@router.post("/organize-folders/apply")
def apply_organize_folders(request: ApplyFoldersRequest, db: Session = Depends(get_db)):
    try:
        return folder_organize_service.apply_draft(db, request.draft_id, request.folder_keys)
    except KeyError:
        raise HTTPException(status_code=404, detail="Folder draft not found")


@router.delete("/organize-folders/draft/{draft_id}", status_code=204)
def discard_organize_folders(draft_id: str):
    folder_organize_service.discard_draft(draft_id)
