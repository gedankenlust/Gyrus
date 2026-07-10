import asyncio
import httpx

from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy.orm import Session
from typing import Dict, Any, Optional, List
from pydantic import BaseModel

from database import get_db, SessionLocal
from models.bookmark import Bookmark
from schemas.bookmark import BrainMessageOut
from services.llm_service import LLMService, LLMUnavailableError
from services.scraper_service import scraper_service, _is_youtube as is_youtube
from services.brain_sync_service import brain_sync_service
from services import brain_chat_service

import logging
logger = logging.getLogger(__name__)

router = APIRouter(prefix="/api/brain", tags=["brain"])

SCRAPED_HEADER = "## Content (Scraped)"
# Bump this when the scraper improves, so cached content from older versions is
# re-scraped once instead of being served stale forever.
SCRAPE_MARKER = "<!-- gyrus-scrape v4 -->"


def _persist_scraped_content(file_path, content: str) -> None:
    """Write freshly scraped content into the bookmark's markdown file,
    replacing any previous scraped section while preserving the chat history
    that follows it."""
    try:
        text = file_path.read_text(encoding="utf-8")
    except Exception:
        return
    section = f"{SCRAPED_HEADER}\n{SCRAPE_MARKER}\n{content}\n"
    if SCRAPED_HEADER in text:
        before, rest = text.split(SCRAPED_HEADER, 1)
        # Keep any following sections (e.g. "## Chat Interaction ...").
        idx = rest.find("\n## ")
        after = rest[idx:] if idx != -1 else ""
        new_text = before.rstrip() + "\n\n" + section + after
    else:
        new_text = text.rstrip() + "\n\n" + section
    try:
        file_path.write_text(new_text, encoding="utf-8")
    except Exception as e:
        logger.warning(f"Failed to persist scraped content: {e}")

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
    embedding_model: Optional[str] = None
    ollama_url: Optional[str] = None


def _provider_model(provider_config: Optional[Dict[str, Any]]) -> str | None:
    if not provider_config:
        return None
    model = provider_config.get("model")
    return model if isinstance(model, str) and model else None

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


@router.post("/config")
async def update_brain_config(config: BrainConfigUpdate):
    brain_sync_service.update_config(config.root_dir, config.is_enabled)
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
    if config.is_enabled:
        asyncio.get_event_loop().run_in_executor(None, _reconcile_brain_blocking)
    return {"status": "ok", "root_dir": str(brain_sync_service.root_dir), "is_enabled": brain_sync_service.is_enabled}


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

async def _prepare_context(db: Session, bookmark) -> str:
    """Build the page context for an LLM chat: read the cached scraped section
    from the bookmark's markdown file, re-scraping when it's missing/stale.
    Shared by the blocking and streaming chat endpoints."""
    file_path = brain_sync_service._get_bookmark_file_path(db, bookmark)
    if not file_path.exists():
        brain_sync_service.sync_bookmark(db, bookmark)

    full_text = ""
    with open(file_path, "r", encoding="utf-8") as f:
        full_text = f.read()

    context = ""
    if "## Content (Scraped)" in full_text:
        sections = full_text.split("## Content (Scraped)")
        if len(sections) > 1:
            context = sections[1].split("\n## ")[0].strip()

    needs_scrape = len(context) < 200 or SCRAPE_MARKER not in context
    if needs_scrape:
        scrape_result = await scraper_service.extract_content(bookmark.url)
        content = scrape_result.get("content", "")
        if content:
            context = content
            _persist_scraped_content(file_path, content)
            from services import bookmark_service, background
            bookmark_service.store_scraped_content(db, bookmark.id, content)
            background.schedule(
                bookmark_service.index_bookmark_embedding(bookmark.id, content)
            )
        elif not context:
            context = f"Title: {bookmark.title}\nDescription: {bookmark.description}\nURL: {bookmark.url}"

    context = context.replace(SCRAPE_MARKER, "").strip()
    MAX_CONTEXT_CHARS = 15000
    if len(context) > MAX_CONTEXT_CHARS:
        context = context[:MAX_CONTEXT_CHARS] + "... [Content Truncated]"
    return context


@router.post("/chat", response_model=ChatResponse)
async def chat_with_bookmark(request: ChatRequest, db: Session = Depends(get_db)):
    # 1. Fetch bookmark
    bookmark = db.query(Bookmark).filter(Bookmark.id == request.bookmark_id).first()
    if not bookmark:
        raise HTTPException(status_code=404, detail="Bookmark not found")

    # 2. Build the page context (cached scrape, re-scraping when stale).
    context = await _prepare_context(db, bookmark)
    model = _provider_model(request.provider_config)
    brain_chat_service.add_message(
        db, bookmark.id, "user", request.prompt, model=model, status="complete"
    )

    # 3. Call LLM — pass the bookmark identity and recent history so every
    #    turn stays anchored to this specific page.
    history = [{"role": m.role, "content": m.content} for m in (request.history or [])]
    try:
        response_text = await LLMService.ask_llm(
            prompt=request.prompt,
            context=context,
            provider_config=request.provider_config,
            title=bookmark.title or "",
            url=bookmark.url or "",
            history=history,
            language=request.language,
        )
    except LLMUnavailableError as e:
        brain_chat_service.add_message(
            db, bookmark.id, "assistant", str(e), model=model, status="error"
        )
        # Clear, user-facing reason (Ollama down, model missing, cloud n/a).
        raise HTTPException(status_code=503, detail=str(e))
    except Exception as e:
        detail = f"LLM Error: {str(e)}"
        brain_chat_service.add_message(
            db, bookmark.id, "assistant", detail, model=model, status="error"
        )
        raise HTTPException(status_code=500, detail=detail)

    brain_chat_service.add_message(
        db, bookmark.id, "assistant", response_text, model=model, status="complete"
    )

    # 4. Append interaction to .md file
    try:
        brain_sync_service.append_interaction(db, bookmark, request.prompt, response_text)
    except Exception as e:
        # Don't fail the whole request if sync fails, but log it
        logger.warning(f"Failed to append interaction: {e}")

    return ChatResponse(response=response_text)


@router.post("/chat/stream")
async def chat_with_bookmark_stream(request: ChatRequest, db: Session = Depends(get_db)):
    """Streaming variant: emits the reply token-by-token (text/plain chunks) so
    the UI can render it live. The full reply is saved to the markdown file when
    the stream completes. Errors are sent as a final line prefixed with the
    sentinel below so the client can show them clearly."""
    from fastapi.responses import StreamingResponse

    bookmark = db.query(Bookmark).filter(Bookmark.id == request.bookmark_id).first()
    if not bookmark:
        raise HTTPException(status_code=404, detail="Bookmark not found")

    context = await _prepare_context(db, bookmark)
    history = [{"role": m.role, "content": m.content} for m in (request.history or [])]
    model = _provider_model(request.provider_config)
    brain_chat_service.add_message(
        db, bookmark.id, "user", request.prompt, model=model, status="complete"
    )

    async def generate():
        collected: list[str] = []
        saved = False
        try:
            async for piece in LLMService.stream_ollama(
                prompt=request.prompt,
                context=context,
                provider_config=request.provider_config,
                title=bookmark.title or "",
                url=bookmark.url or "",
                history=history,
                language=request.language,
            ):
                collected.append(piece)
                yield piece
        except LLMUnavailableError as e:
            brain_chat_service.add_message(
                db, bookmark.id, "assistant", str(e), model=model, status="error"
            )
            saved = True
            yield f"\n\n[GYRUS-ERROR] {e}"
            return
        except asyncio.CancelledError:
            if collected:
                full = "".join(collected)
                brain_chat_service.add_message(
                    db, bookmark.id, "assistant", full, model=model, status="stopped"
                )
                saved = True
                try:
                    brain_sync_service.append_interaction(db, bookmark, request.prompt, full)
                except Exception as e:
                    logger.warning(f"Failed to append stopped interaction: {e}")
            raise
        except Exception as e:
            brain_chat_service.add_message(
                db, bookmark.id, "assistant", str(e), model=model, status="error"
            )
            saved = True
            yield f"\n\n[GYRUS-ERROR] {e}"
            return

        # Persist the completed answer (best-effort) once streaming finishes.
        full = "".join(collected)
        if full and not saved:
            brain_chat_service.add_message(
                db, bookmark.id, "assistant", full, model=model, status="complete"
            )
            try:
                brain_sync_service.append_interaction(db, bookmark, request.prompt, full)
            except Exception as e:
                logger.warning(f"Failed to append interaction: {e}")

    return StreamingResponse(generate(), media_type="text/plain; charset=utf-8")


class SummarizeRequest(BaseModel):
    provider_config: Optional[Dict[str, Any]] = {"provider": "ollama", "model": "llama3"}
    language: Optional[str] = None


class SummarizeResponse(BaseModel):
    summary: str


@router.post("/summarize/{bookmark_id}", response_model=SummarizeResponse)
async def summarize_bookmark(bookmark_id: str, request: SummarizeRequest = SummarizeRequest(),
                             db: Session = Depends(get_db)):
    """Generate a 2-3 sentence summary of a bookmark's page content using the
    local LLM, then save it as an AI note. Idempotent: safe to call again to
    refresh the summary. Requires Ollama and the AI Brain to be enabled."""
    bookmark = db.query(Bookmark).filter(Bookmark.id == bookmark_id).first()
    if not bookmark:
        raise HTTPException(status_code=404, detail="Bookmark not found")

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
            # Was hardcoded to "llama3" regardless of the user's configured
            # model/URL — every other AI Brain endpoint (chat, auto-tag)
            # already takes this from the client. Anyone not literally
            # running llama3 got a 503 no matter what they had set up.
            provider_config=request.provider_config,
            title=bookmark.title or "",
            url=bookmark.url or "",
            language=request.language,
        )
    except LLMUnavailableError as e:
        raise HTTPException(status_code=503, detail=str(e))
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"LLM Error: {str(e)}")

    if summary and summary.strip():
        from services import bookmark_service
        bookmark_service.add_note(db, bookmark_id, summary.strip(), source="ai")

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
