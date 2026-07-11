"""Chat: friendly error mapping + token streaming."""
import pytest

from services import llm_service as llm_module
from services import scraper_service as scraper_module
from services.site_structure_service import site_structure_service
from services.llm_service import LLMUnavailableError
from services.brain_sync_service import brain_sync_service


@pytest.fixture
def brain_enabled(tmp_path):
    brain_sync_service.update_config(str(tmp_path), True)
    yield
    brain_sync_service.update_config(None, False)


def _make_bookmark(client):
    return client.post("/api/bookmarks", json={
        "title": "Page", "url": "https://example.com/p", "source": "manual"}).json()


def test_unavailable_llm_returns_503(client, brain_enabled, monkeypatch):
    async def fake_scrape(url):
        return {"content": "some content long enough to be used as context " * 5, "title": "T"}

    async def boom(*a, **k):
        raise LLMUnavailableError("Couldn't reach Ollama. Make sure it's running.")

    monkeypatch.setattr(scraper_module.scraper_service, "extract_content", fake_scrape)
    monkeypatch.setattr(llm_module.LLMService, "ask_llm", boom)

    bm = _make_bookmark(client)
    resp = client.post("/api/brain/chat", json={
        "bookmark_id": bm["id"], "prompt": "hi",
        "provider_config": {"provider": "ollama", "model": "llama3"}})

    assert resp.status_code == 503
    assert "Ollama" in resp.json()["detail"]


def test_chat_stream_emits_tokens(client, brain_enabled, monkeypatch):
    async def fake_scrape(url):
        return {"content": "content long enough to serve as context " * 5, "title": "T"}

    async def fake_stream(prompt, context, provider_config, title="", url="", history=None, language=None):
        for tok in ["Hel", "lo ", "world"]:
            yield tok

    monkeypatch.setattr(scraper_module.scraper_service, "extract_content", fake_scrape)
    monkeypatch.setattr(llm_module.LLMService, "stream_ollama", fake_stream)

    bm = _make_bookmark(client)
    resp = client.post("/api/brain/chat/stream", json={
        "bookmark_id": bm["id"], "prompt": "hi",
        "provider_config": {"provider": "ollama", "model": "llama3"}})

    assert resp.status_code == 200
    assert resp.text == "Hello world"

    history = client.get(f"/api/brain/bookmarks/{bm['id']}/messages")
    assert history.status_code == 200
    messages = history.json()
    assert [(m["role"], m["content"], m["status"]) for m in messages] == [
        ("user", "hi", "complete"),
        ("assistant", "Hello world", "complete"),
    ]


def test_chat_stream_answers_page_count_without_llm(client, brain_enabled, monkeypatch):
    async def fake_data_for_url(bookmark_id, url, force_refresh=False):
        return {
            "origin": "https://example.com",
            "pages": [{"url": "https://example.com/", "path": "/", "title": "Home"}],
            "limit": 80,
            "limit_reached": False,
            "sitemap_pages": 1,
            "sitemap_page_urls": ["https://example.com/"],
            "sitemap_sources": ["https://example.com/sitemap.xml"],
            "errors": [],
        }

    async def stream_should_not_run(*args, **kwargs):
        raise AssertionError("LLM stream should not be called for page-count questions")
        yield  # pragma: no cover

    monkeypatch.setattr(site_structure_service, "data_for_url", fake_data_for_url)
    monkeypatch.setattr(llm_module.LLMService, "stream_ollama", stream_should_not_run)

    bm = _make_bookmark(client)
    resp = client.post("/api/brain/chat/stream", json={
        "bookmark_id": bm["id"],
        "prompt": "Wie viele Seiten hat die Webseite?",
        "provider_config": {"provider": "ollama", "model": "llama3"},
        "language": "de",
    })

    assert resp.status_code == 200
    assert "Die Sitemap listet 1 interne Seiten/URLs" in resp.text
    assert "keine LLM-Schätzung" in resp.text


def test_chat_stream_reports_error_inline(client, brain_enabled, monkeypatch):
    async def fake_scrape(url):
        return {"content": "content long enough to serve as context " * 5, "title": "T"}

    async def boom_stream(*a, **k):
        raise LLMUnavailableError("Ollama not running")
        yield  # pragma: no cover (makes this an async generator)

    monkeypatch.setattr(scraper_module.scraper_service, "extract_content", fake_scrape)
    monkeypatch.setattr(llm_module.LLMService, "stream_ollama", boom_stream)

    bm = _make_bookmark(client)
    resp = client.post("/api/brain/chat/stream", json={
        "bookmark_id": bm["id"], "prompt": "hi",
        "provider_config": {"provider": "ollama", "model": "llama3"}})

    assert resp.status_code == 200
    assert "[GYRUS-ERROR]" in resp.text
    assert "Ollama" in resp.text

    messages = client.get(f"/api/brain/bookmarks/{bm['id']}/messages").json()
    assert messages[-1]["role"] == "assistant"
    assert messages[-1]["status"] == "error"
    assert "Ollama" in messages[-1]["content"]


def test_chat_history_can_be_cleared(client, db, brain_enabled, monkeypatch):
    async def fake_scrape(url):
        return {"content": "content long enough to serve as context " * 5, "title": "T"}

    async def fake_stream(prompt, context, provider_config, title="", url="", history=None, language=None):
        yield "Saved"

    monkeypatch.setattr(scraper_module.scraper_service, "extract_content", fake_scrape)
    monkeypatch.setattr(llm_module.LLMService, "stream_ollama", fake_stream)

    bm = _make_bookmark(client)
    client.post("/api/brain/chat/stream", json={
        "bookmark_id": bm["id"], "prompt": "remember this",
        "provider_config": {"provider": "ollama", "model": "llama3"}})
    assert len(client.get(f"/api/brain/bookmarks/{bm['id']}/messages").json()) == 2

    resp = client.delete(f"/api/brain/bookmarks/{bm['id']}/messages")
    assert resp.status_code == 200
    assert resp.json()["deleted"] == 2
    assert client.get(f"/api/brain/bookmarks/{bm['id']}/messages").json() == []

    from services.brain_sync_service import brain_sync_service
    from models.bookmark import Bookmark
    bookmark = db.query(Bookmark).filter(Bookmark.id == bm["id"]).first()
    md = brain_sync_service._get_bookmark_file_path(db, bookmark).read_text()
    assert "## Chat Interaction" not in md
