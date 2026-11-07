import asyncio
import httpx

from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy.orm import Session
from starlette.concurrency import run_in_threadpool
from typing import Dict, Any, Optional, List
from pydantic import BaseModel

from database import get_db, SessionLocal
from models.bookmark import Bookmark
from schemas.bookmark import BrainMessageOut
from services.llm_service import LLMService, LLMUnavailableError
from services.brain_sync_service import brain_sync_service
from services import ai_policy
from services import brain_chat_service
from services import visual_snapshot_service
from services import visual_snapshot_job_service
from services.site_structure_service import site_structure_service
# Context building lives in services/brain_context_service.py; these names are
# re-exported because callers and tests import them from this router.
from services.brain_context_service import (  # noqa: F401
    SCRAPE_MARKER,
    SCRAPED_HEADER,
    _persist_scraped_content,
    _scrape_source_marker,
    prepare_context as _prepare_context,
)

import logging
logger = logging.getLogger(__name__)
LLM_FAILURE_MESSAGE = "LLM Error: the language model request failed. Check the AI settings and try again."

router = APIRouter(prefix="/api/brain", tags=["brain"])

class ChatMessage(BaseModel):
    role: str
    content: str

class ChatRequest(BaseModel):
    bookmark_id: str
    prompt: str
    provider_config: Optional[Dict[str, Any]] = {"provider": "ollama", "model": "llama3"}
    history: Optional[list[ChatMessage]] = None
    # "en" / "de" — the app's UI language, so replies match it regardless of
    # what language the question or the page content is in.
    language: Optional[str] = None

class ChatResponse(BaseModel):
    response: str

class BrainConfigUpdate(BaseModel):
    root_dir: Optional[str] = None
    is_enabled: bool = False
    ai_enabled: bool = False
    embedding_model: Optional[str] = None
    ollama_url: Optional[str] = None


def _provider_model(provider_config: Optional[Dict[str, Any]]) -> str | None:
    if not provider_config:
        return None
    model = provider_config.get("model")
    return model if isinstance(model, str) and model else None


def _save_assistant_reply(db: Session, bookmark, prompt: str, response_text: str, model: str | None) -> None:
    brain_chat_service.add_message(
        db, bookmark.id, "assistant", response_text, model=model, status="complete"
    )
    try:
        brain_sync_service.append_interaction(db, bookmark, prompt, response_text)
    except Exception as e:
        logger.warning(f"Failed to append interaction: {e}")


def _save_stopped_reply(db: Session, bookmark, prompt: str, response_text: str, model: str | None) -> None:
    brain_chat_service.add_message(
        db, bookmark.id, "assistant", response_text, model=model, status="stopped"
    )
    try:
        brain_sync_service.append_interaction(db, bookmark, prompt, response_text)
    except Exception as e:
        logger.warning(f"Failed to append stopped interaction: {e}")


def _save_error_reply(db: Session, bookmark_id: str, message: str, model: str | None) -> None:
    brain_chat_service.add_message(
        db, bookmark_id, "assistant", message, model=model, status="error"
    )


def _bookmark_or_404(db: Session, bookmark_id: str) -> Bookmark:
    bookmark = db.query(Bookmark).filter(Bookmark.id == bookmark_id).first()
    if not bookmark:
        raise HTTPException(status_code=404, detail="Bookmark not found")
    return bookmark


def _start_chat(db: Session, bookmark_id: str, prompt: str, model: str | None):
    """Record the user's question. Returns the bookmark and plain copies of
    the fields the LLM call needs: after the commit its attributes are
    expired, and reading them on the event loop would query the database."""
    bookmark = _bookmark_or_404(db, bookmark_id)
    brain_chat_service.add_message(
        db, bookmark.id, "user", prompt, model=model, status="complete"
    )
    return bookmark, bookmark.id, bookmark.title or "", bookmark.url or ""


def _reconcile_brain_blocking():
    """Reconcile folder structure + rebuild the index, with its own session.
    Heavy for large libraries, so it runs OFF the event loop (see /config)."""
    db = SessionLocal()
    try:
        brain_sync_service.resync_all(db)
    except Exception as e:
        logger.warning(f"Brain resync failed: {e}")
    finally:
        db.close()


# The settings are applied in two steps around a threadpool call; without this
# two quick pushes could interleave and leave AI and Brain flags from different
# requests.
_config_lock = asyncio.Lock()


@router.post("/config")
async def update_brain_config(config: BrainConfigUpdate):
    async with _config_lock:
        ai_policy.configure(config.ai_enabled)
        # Enabling the Brain creates its folder: filesystem work, off the loop.
        await run_in_threadpool(
            brain_sync_service.update_config,
            config.root_dir,
            config.is_enabled and config.ai_enabled,
        )
        # Embeddings run server-side with no per-request model, so remember the
        # chosen embedding model / Ollama URL here. A model change takes effect for
        # new bookmarks immediately; existing ones need a reindex (different vector
        # size), which the app prompts for.
        from services import embedding_service
        embedding_service.set_active_model(config.embedding_model)
        embedding_service.set_active_base_url(config.ollama_url)
        # The app pushes the config on every launch. Reconciling + rebuilding the
        # index can be heavy with many bookmarks, so run it on a worker thread —
        # otherwise it blocks the event loop and the app shows an empty list at
        # startup until it finishes.
        if brain_sync_service.is_enabled:
            from services import background
            background.schedule(asyncio.to_thread(_reconcile_brain_blocking))
        return {"status": "ok", "root_dir": str(brain_sync_service.root_dir), "is_enabled": brain_sync_service.is_enabled}


@router.get("/index-path")
def brain_index_path():
    return {"path": str(brain_sync_service.index_path())}


@router.get("/bookmarks/{bookmark_id}/messages", response_model=list[BrainMessageOut])
def list_brain_messages(bookmark_id: str, db: Session = Depends(get_db)):
    bookmark = db.query(Bookmark).filter(Bookmark.id == bookmark_id).first()
    if not bookmark:
        raise HTTPException(status_code=404, detail="Bookmark not found")
    return brain_chat_service.list_messages(db, bookmark_id)


@router.delete("/bookmarks/{bookmark_id}/messages")
def clear_brain_messages(bookmark_id: str, db: Session = Depends(get_db)):
    bookmark = db.query(Bookmark).filter(Bookmark.id == bookmark_id).first()
    if not bookmark:
        raise HTTPException(status_code=404, detail="Bookmark not found")
    deleted = brain_chat_service.clear_messages(db, bookmark_id)
    brain_sync_service.clear_chat_interactions(db, bookmark)
    return {"deleted": deleted}


@router.get("/bookmarks/{bookmark_id}/visual-snapshot")
def get_visual_snapshot(bookmark_id: str, db: Session = Depends(get_db)):
    bookmark = db.query(Bookmark).filter(Bookmark.id == bookmark_id).first()
    if not bookmark:
        raise HTTPException(status_code=404, detail="Bookmark not found")
    snapshot = visual_snapshot_service.read_snapshot(bookmark_id)
    if snapshot is None:
        raise HTTPException(status_code=404, detail="Visual snapshot not found")
    return snapshot


@router.post("/bookmarks/{bookmark_id}/visual-snapshot")
async def create_visual_snapshot(bookmark_id: str, db: Session = Depends(get_db)):
    bookmark = await run_in_threadpool(_bookmark_or_404, db, bookmark_id)
    try:
        return await visual_snapshot_service.capture_snapshot(
            bookmark.id, bookmark.url, title=bookmark.title or ""
        )
    except visual_snapshot_service.VisualSnapshotUnavailable as e:
        raise HTTPException(status_code=503, detail=str(e))


@router.post("/bookmarks/{bookmark_id}/visual-snapshot/job")
async def start_visual_snapshot_job(bookmark_id: str, db: Session = Depends(get_db)):
    bookmark = await run_in_threadpool(_bookmark_or_404, db, bookmark_id)
    status = visual_snapshot_job_service.get_status()
    if status.get("running") and status.get("bookmark_id") != bookmark_id:
        raise HTTPException(status_code=409, detail="Another design inspection is already running")
    return await visual_snapshot_job_service.start(
        bookmark.id, bookmark.url, title=bookmark.title or ""
    )


@router.get("/bookmarks/{bookmark_id}/visual-snapshot/job")
def get_visual_snapshot_job(bookmark_id: str, db: Session = Depends(get_db)):
    bookmark = db.query(Bookmark).filter(Bookmark.id == bookmark_id).first()
    if not bookmark:
        raise HTTPException(status_code=404, detail="Bookmark not found")
    status = visual_snapshot_job_service.get_status()
    if status.get("bookmark_id") not in {None, bookmark_id}:
        return {
            "running": False,
            "bookmark_id": bookmark_id,
            "stage": "idle",
            "completed": 0,
            "total": visual_snapshot_service.DESIGN_INSPECTION_STEPS,
            "snapshot": None,
            "error": None,
        }
    return status


@router.post("/bookmarks/{bookmark_id}/visual-snapshot/job/cancel")
def cancel_visual_snapshot_job(bookmark_id: str, db: Session = Depends(get_db)):
    bookmark = db.query(Bookmark).filter(Bookmark.id == bookmark_id).first()
    if not bookmark:
        raise HTTPException(status_code=404, detail="Bookmark not found")
    status = visual_snapshot_job_service.get_status()
    if status.get("bookmark_id") != bookmark_id:
        return status
    return visual_snapshot_job_service.cancel()


@router.get("/bookmarks/{bookmark_id}/visual-snapshot/runs")
def get_visual_snapshot_runs(bookmark_id: str, db: Session = Depends(get_db)):
    bookmark = db.query(Bookmark).filter(Bookmark.id == bookmark_id).first()
    if not bookmark:
        raise HTTPException(status_code=404, detail="Bookmark not found")
    return visual_snapshot_service.list_snapshot_runs(bookmark_id)


@router.get("/bookmarks/{bookmark_id}/visual-snapshot/runs/{run_id}")
def get_visual_snapshot_run(bookmark_id: str, run_id: str, db: Session = Depends(get_db)):
    bookmark = db.query(Bookmark).filter(Bookmark.id == bookmark_id).first()
    if not bookmark:
        raise HTTPException(status_code=404, detail="Bookmark not found")
    snapshot = visual_snapshot_service.read_snapshot_run(bookmark_id, run_id)
    if snapshot is None:
        raise HTTPException(status_code=404, detail="Visual snapshot run not found")
    return snapshot

@router.post("/chat", response_model=ChatResponse, dependencies=[Depends(ai_policy.require_ai)])
async def chat_with_bookmark(request: ChatRequest, db: Session = Depends(get_db)):
    # Every database / Brain mirror step runs in the threadpool, one at a time
    # on this request's session; the loop only awaits the crawl and the LLM.
    # 1. Fetch bookmark and record the question.
    model = _provider_model(request.provider_config)
    bookmark, bookmark_id, title, url = await run_in_threadpool(
        _start_chat, db, request.bookmark_id, request.prompt, model
    )

    if site_structure_service.is_page_count_prompt(request.prompt):
        response_text = await site_structure_service.page_count_answer_for_url(
            bookmark_id, url, language=request.language
        )
        await run_in_threadpool(_save_assistant_reply, db, bookmark, request.prompt, response_text, model)
        return ChatResponse(response=response_text)

    # 2. Build the page context (cached scrape, re-scraping when stale).
    context = await _prepare_context(db, bookmark, request.prompt)

    # 3. Call LLM — pass the bookmark identity and recent history so every
    #    turn stays anchored to this specific page.
    history = [{"role": m.role, "content": m.content} for m in (request.history or [])]
    try:
        response_text = await LLMService.ask_llm(
            prompt=request.prompt,
            context=context,
            provider_config=request.provider_config,
            title=title,
            url=url,
            history=history,
            language=request.language,
        )
    except LLMUnavailableError as e:
        await run_in_threadpool(_save_error_reply, db, bookmark_id, str(e), model)
        # Clear, user-facing reason (Ollama down, model missing, cloud n/a).
        raise HTTPException(status_code=503, detail=str(e))
    except Exception:
        # Provider exceptions can carry URLs, local file paths or raw response
        # bodies; log them, but show and persist only a fixed message.
        logger.exception("Brain chat LLM request failed for bookmark %s", bookmark_id)
        await run_in_threadpool(_save_error_reply, db, bookmark_id, LLM_FAILURE_MESSAGE, model)
        raise HTTPException(status_code=500, detail=LLM_FAILURE_MESSAGE)

    await run_in_threadpool(_save_assistant_reply, db, bookmark, request.prompt, response_text, model)

    return ChatResponse(response=response_text)


@router.post("/chat/stream", dependencies=[Depends(ai_policy.require_ai)])
async def chat_with_bookmark_stream(request: ChatRequest, db: Session = Depends(get_db)):
    """Streaming variant: emits the reply token-by-token (text/plain chunks) so
    the UI can render it live. The full reply is saved to the markdown file when
    the stream completes. Errors are sent as a final line prefixed with the
    sentinel below so the client can show them clearly."""
    from fastapi.responses import StreamingResponse

    model = _provider_model(request.provider_config)
    bookmark, bookmark_id, title, url = await run_in_threadpool(
        _start_chat, db, request.bookmark_id, request.prompt, model
    )

    if site_structure_service.is_page_count_prompt(request.prompt):
        response_text = await site_structure_service.page_count_answer_for_url(
            bookmark_id, url, language=request.language
        )
        await run_in_threadpool(_save_assistant_reply, db, bookmark, request.prompt, response_text, model)
        return StreamingResponse(iter([response_text]), media_type="text/plain; charset=utf-8")

    context = await _prepare_context(db, bookmark, request.prompt)
    history = [{"role": m.role, "content": m.content} for m in (request.history or [])]

    # The generator runs on the event loop while the response streams; the
    # request's session stays open until then (FastAPI closes yield
    # dependencies after the response). Saves go through the threadpool,
    # which anyio lets finish even while the stream is being cancelled.
    async def generate():
        collected: list[str] = []
        saved = False
        try:
            async for piece in LLMService.stream_ollama(
                prompt=request.prompt,
                context=context,
                provider_config=request.provider_config,
                title=title,
                url=url,
                history=history,
                language=request.language,
            ):
                collected.append(piece)
                yield piece
        except LLMUnavailableError as e:
            await run_in_threadpool(_save_error_reply, db, bookmark_id, str(e), model)
            saved = True
            yield f"\n\n[GYRUS-ERROR] {e}"
            return
        except asyncio.CancelledError:
            if collected:
                full = "".join(collected)
                await run_in_threadpool(_save_stopped_reply, db, bookmark, request.prompt, full, model)
                saved = True
            raise
        except Exception:
            logger.exception("Brain chat stream failed for bookmark %s", bookmark_id)
            await run_in_threadpool(_save_error_reply, db, bookmark_id, LLM_FAILURE_MESSAGE, model)
            saved = True
            yield f"\n\n[GYRUS-ERROR] {LLM_FAILURE_MESSAGE}"
            return

        # Persist the completed answer (best-effort) once streaming finishes.
        full = "".join(collected)
        if full and not saved:
            await run_in_threadpool(_save_assistant_reply, db, bookmark, request.prompt, full, model)

    return StreamingResponse(generate(), media_type="text/plain; charset=utf-8")


class SummarizeRequest(BaseModel):
    provider_config: Optional[Dict[str, Any]] = {"provider": "ollama", "model": "llama3"}
    language: Optional[str] = None


class SummarizeResponse(BaseModel):
    summary: str


def _bookmark_identity(db: Session, bookmark_id: str):
    bookmark = _bookmark_or_404(db, bookmark_id)
    return bookmark, bookmark.title or "", bookmark.url or ""


@router.post("/summarize/{bookmark_id}", response_model=SummarizeResponse, dependencies=[Depends(ai_policy.require_ai)])
async def summarize_bookmark(bookmark_id: str, request: SummarizeRequest = SummarizeRequest(),
                             db: Session = Depends(get_db)):
    """Generate a 2-3 sentence summary of a bookmark's page content using the
    local LLM, then save it as an AI note. Idempotent: safe to call again to
    refresh the summary. Requires Ollama and the AI Brain to be enabled."""
    bookmark, title, url = await run_in_threadpool(_bookmark_identity, db, bookmark_id)

    context = await _prepare_context(db, bookmark)

    if request.language == "de":
        summarize_prompt = (
            "Fasse diese Seite in 2-3 klaren, informativen Sätzen zusammen. "
            "Konzentriere dich darauf, worum es wirklich geht. "
            "Beginne nicht mit 'Diese Seite' oder 'Dieser Artikel'."
        )
    else:
        summarize_prompt = (
            "Summarize this page in 2-3 clear, informative sentences. "
            "Focus on what it's actually about. "
            "Do not start with 'This page' or 'This article'."
        )

    try:
        summary = await LLMService.ask_llm(
            prompt=summarize_prompt,
            context=context,
            provider_config=request.provider_config,
            title=title,
            url=url,
            language=request.language,
        )
    except LLMUnavailableError as e:
        raise HTTPException(status_code=503, detail=str(e))
    except Exception:
        logger.exception("Summarize LLM request failed for bookmark %s", bookmark_id)
        raise HTTPException(status_code=500, detail=LLM_FAILURE_MESSAGE)

    if summary and summary.strip():
        from services import bookmark_service
        await run_in_threadpool(bookmark_service.add_note, db, bookmark_id, summary.strip(), source="ai")

    return SummarizeResponse(summary=summary or "")


class AvailableModelsResponse(BaseModel):
    """Installed Ollama models, split by capability so the app can offer the
    right models in each picker: chat/text models for the LLM, embedding models
    for semantic search. (`models` is kept as the flat union for compatibility.)"""
    models: List[str] = []
    text_models: List[str] = []
    embedding_models: List[str] = []
    error: Optional[str] = None


@router.get("/available-models", response_model=AvailableModelsResponse)
async def get_available_models(url: str = "http://localhost:11434"):
    """List installed Ollama models, classified by capability via /api/show.

    A model is an *embedding* model if its capabilities include 'embedding'
    (e.g. nomic-embed-text, bge-m3); otherwise it's offered as a *text* model
    (completion/chat). Showing only embedding models in the embedding picker
    prevents picking a chat model like llava that can't embed."""
    try:
        async with httpx.AsyncClient(timeout=5.0) as client:
            resp = await client.get(f"{url}/api/tags")
            resp.raise_for_status()
            names = [m.get("name", "") for m in resp.json().get("models", []) if m.get("name")]

            async def caps(name: str):
                try:
                    r = await client.post(f"{url}/api/show", json={"model": name})
                    r.raise_for_status()
                    return name, (r.json().get("capabilities") or [])
                except Exception:
                    return name, []

            classified = await asyncio.gather(*[caps(n) for n in names])

        text_models, embedding_models = [], []
        for name, cap_list in classified:
            if "embedding" in cap_list:
                embedding_models.append(name)
            else:
                # completion / tools / vision / unknown → usable as a text model
                text_models.append(name)
        return AvailableModelsResponse(
            models=sorted(names),
            text_models=sorted(text_models),
            embedding_models=sorted(embedding_models),
        )
    except httpx.HTTPError:
        return AvailableModelsResponse(error=f"Ollama unreachable at {url}")
    except Exception as e:
        return AvailableModelsResponse(error=f"Failed to list models: {str(e)}")
