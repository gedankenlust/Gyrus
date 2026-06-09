import asyncio

from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy.orm import Session
from typing import Dict, Any, Optional
from pydantic import BaseModel

from database import get_db, SessionLocal
from models.bookmark import Bookmark
from services.llm_service import LLMService
from services.scraper_service import scraper_service, _is_youtube as is_youtube
from services.brain_sync_service import brain_sync_service

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
        print(f"Failed to persist scraped content: {e}")

class ChatMessage(BaseModel):
    role: str
    content: str

class ChatRequest(BaseModel):
    bookmark_id: str
    prompt: str
    provider_config: Optional[Dict[str, Any]] = {"provider": "ollama", "model": "llama3"}
    history: Optional[list[ChatMessage]] = None

class ChatResponse(BaseModel):
    response: str

class BrainConfigUpdate(BaseModel):
    root_dir: Optional[str] = None
    is_enabled: bool = False

def _reconcile_brain_blocking():
    """Reconcile folder structure + rebuild the index, with its own session.
    Heavy for large libraries, so it runs OFF the event loop (see /config)."""
    db = SessionLocal()
    try:
        brain_sync_service.resync_all(db)
    except Exception as e:
        print(f"Brain resync failed: {e}")
    finally:
        db.close()


@router.post("/config")
async def update_brain_config(config: BrainConfigUpdate):
    brain_sync_service.update_config(config.root_dir, config.is_enabled)
    # The app pushes the config on every launch. Reconciling + rebuilding the
    # index can be heavy with many bookmarks, so run it on a worker thread —
    # otherwise it blocks the event loop and the app shows an empty list at
    # startup until it finishes.
    if config.is_enabled:
        asyncio.get_event_loop().run_in_executor(None, _reconcile_brain_blocking)
    return {"status": "ok", "root_dir": str(brain_sync_service.root_dir), "is_enabled": brain_sync_service.is_enabled}

@router.post("/chat", response_model=ChatResponse)
async def chat_with_bookmark(request: ChatRequest, db: Session = Depends(get_db)):
    # 1. Fetch bookmark
    bookmark = db.query(Bookmark).filter(Bookmark.id == request.bookmark_id).first()
    if not bookmark:
        raise HTTPException(status_code=404, detail="Bookmark not found")

    # 2. Get context (check markdown file first to avoid redundant scraping)
    file_path = brain_sync_service._get_bookmark_file_path(db, bookmark)
    
    # Ensure the file/directory exists
    if not file_path.exists():
        brain_sync_service.sync_bookmark(db, bookmark)
    
    full_text = ""
    with open(file_path, "r", encoding="utf-8") as f:
        full_text = f.read()

    # Extract specifically the scraped content section to avoid prompt bloat from chat history
    context = ""
    if "## Content (Scraped)" in full_text:
        sections = full_text.split("## Content (Scraped)")
        if len(sections) > 1:
            # Get everything after the header, but stop before next section if any
            scraped_part = sections[1].split("\n## ")[0].strip()
            context = scraped_part

    # Re-scrape when the cached content is missing/too thin, or when it was
    # produced by an older scraper version (no current marker) — this heals
    # stale caches (e.g. content saved before structured-data extraction) once.
    needs_scrape = len(context) < 200 or SCRAPE_MARKER not in context

    if needs_scrape:
        scrape_result = await scraper_service.extract_content(bookmark.url)
        content = scrape_result.get("content", "")
        if content:
            context = content
            _persist_scraped_content(file_path, content)
            # Also cache it on the bookmark for full-text content search.
            from services import bookmark_service
            bookmark_service.store_scraped_content(db, bookmark.id, content)
        elif not context:
            # Fallback to metadata
            context = f"Title: {bookmark.title}\nDescription: {bookmark.description}\nURL: {bookmark.url}"

    # The version marker is bookkeeping, not page content — keep it out of the prompt.
    context = context.replace(SCRAPE_MARKER, "").strip()

    # Cap context length (approx. 15,000 chars)
    MAX_CONTEXT_CHARS = 15000
    if len(context) > MAX_CONTEXT_CHARS:
        context = context[:MAX_CONTEXT_CHARS] + "... [Content Truncated]"

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
        )
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"LLM Error: {str(e)}")

    # 4. Append interaction to .md file
    try:
        brain_sync_service.append_interaction(db, bookmark, request.prompt, response_text)
    except Exception as e:
        # Don't fail the whole request if sync fails, but log it
        print(f"Failed to append interaction: {e}")

    return ChatResponse(response=response_text)
