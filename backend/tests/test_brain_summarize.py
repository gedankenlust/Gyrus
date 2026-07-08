"""Summarize must use the caller's actual provider_config (model/URL), not a
hardcoded "llama3" — that bug made the button 503 for anyone running a
different model (which is the common case, e.g. qwen3:8b)."""
import pytest

from services import llm_service as llm_module
from services import scraper_service as scraper_module
from services.brain_sync_service import brain_sync_service


@pytest.fixture
def brain_enabled(tmp_path):
    # Self-contained (doesn't rely on the global singleton's state left by
    # whatever test ran before this one in the same session).
    brain_sync_service.update_config(str(tmp_path), True)
    yield
    brain_sync_service.update_config(None, False)


def test_summarize_uses_the_requests_provider_config(client, brain_enabled, monkeypatch):
    captured = {}

    async def fake_scrape(url):
        return {"content": "Some page content.", "title": "T"}

    async def fake_ask_llm(prompt, context, provider_config, title="", url="", history=None):
        captured["provider_config"] = provider_config
        return "A short summary."

    monkeypatch.setattr(scraper_module.scraper_service, "extract_content", fake_scrape)
    monkeypatch.setattr(llm_module.LLMService, "ask_llm", fake_ask_llm)

    bm = client.post("/api/bookmarks", json={
        "title": "T", "url": "https://example.com/page", "source": "manual",
    }).json()

    resp = client.post(f"/api/brain/summarize/{bm['id']}", json={
        "provider_config": {"provider": "ollama", "model": "qwen3:8b", "ollama_url": "http://localhost:11434"},
    })

    assert resp.status_code == 200
    assert resp.json()["summary"] == "A short summary."
    # The model the caller actually configured reached the LLM call — not a
    # hardcoded "llama3".
    assert captured["provider_config"]["model"] == "qwen3:8b"


def test_summarize_without_a_body_falls_back_to_default(client, brain_enabled, monkeypatch):
    # Older/omitted request bodies must not 422 — the field is optional.
    async def fake_scrape(url):
        return {"content": "Some page content.", "title": "T"}

    async def fake_ask_llm(prompt, context, provider_config, title="", url="", history=None):
        return "A short summary."

    monkeypatch.setattr(scraper_module.scraper_service, "extract_content", fake_scrape)
    monkeypatch.setattr(llm_module.LLMService, "ask_llm", fake_ask_llm)

    bm = client.post("/api/bookmarks", json={
        "title": "T", "url": "https://example.com/page2", "source": "manual",
    }).json()

    resp = client.post(f"/api/brain/summarize/{bm['id']}")
    assert resp.status_code == 200
