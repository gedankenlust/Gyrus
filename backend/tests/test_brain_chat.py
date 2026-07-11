"""The AI Brain chat must feed the page content (and bookmark identity) to the
LLM, so it can actually answer about the page being viewed."""
import pytest

from services import llm_service as llm_module
from services import scraper_service as scraper_module
from services.site_structure_service import site_structure_service
from services.brain_sync_service import brain_sync_service


@pytest.fixture
def brain_enabled(tmp_path):
    original_root = brain_sync_service.root_dir
    original_enabled = brain_sync_service.is_enabled
    brain_sync_service.update_config(str(tmp_path), True)
    yield
    brain_sync_service.root_dir = original_root
    brain_sync_service.is_enabled = original_enabled


def test_chat_passes_scraped_page_content_to_llm(client, brain_enabled, monkeypatch):
    captured = {}

    async def fake_scrape(url):
        return {"content": "Harry Kane is 188 cm tall. Plays for Bayern München.", "title": "Harry Kane"}

    async def fake_ask_llm(prompt, context, provider_config, title="", url="", history=None, language=None):
        captured["prompt"] = prompt
        captured["context"] = context
        captured["title"] = title
        captured["url"] = url
        captured["history"] = history
        return "He is 188 cm tall."

    monkeypatch.setattr(scraper_module.scraper_service, "extract_content", fake_scrape)
    monkeypatch.setattr(llm_module.LLMService, "ask_llm", fake_ask_llm)

    bm = client.post("/api/bookmarks", json={
        "title": "Harry Kane",
        "url": "https://www.fotmob.com/de/players/194165/harry-kane",
        "source": "manual",
    }).json()

    resp = client.post("/api/brain/chat", json={
        "bookmark_id": bm["id"],
        "prompt": "How tall is he?",
        "provider_config": {"provider": "ollama", "model": "llama3"},
        "history": [{"role": "user", "content": "hi"}, {"role": "assistant", "content": "hello"}],
    })

    assert resp.status_code == 200
    # The scraped page content reached the model...
    assert "188 cm" in captured["context"]
    # ...along with the bookmark identity and the prior conversation.
    assert captured["title"] == "Harry Kane"
    assert "fotmob.com" in captured["url"]
    assert captured["history"] == [
        {"role": "user", "content": "hi"},
        {"role": "assistant", "content": "hello"},
    ]


def test_chat_includes_visual_snapshot_context(client, brain_enabled, monkeypatch):
    captured = {}

    async def fake_scrape(url):
        return {"content": "Page text long enough to become context. " * 8, "title": "Design Ref"}

    async def fake_ask_llm(prompt, context, provider_config, title="", url="", history=None, language=None):
        captured["context"] = context
        return "Snapshot-aware answer."

    monkeypatch.setattr(scraper_module.scraper_service, "extract_content", fake_scrape)
    monkeypatch.setattr(llm_module.LLMService, "ask_llm", fake_ask_llm)

    bm = client.post("/api/bookmarks", json={
        "title": "Design Ref",
        "url": "https://design.example",
        "source": "manual",
    }).json()

    snapshot = {
        "bookmark_id": bm["id"],
        "captured_at": "2026-07-11T07:00:00+00:00",
        "viewports": [{
            "name": "desktop",
            "width": 1440,
            "height": 1200,
            "page_title": "Design Ref",
            "dominant_colors": ["#ff3366"],
            "observed_colors": ["rgb(17, 24, 39)"],
            "observed_fonts": ["Inter, sans-serif"],
            "structure": {"links": 4, "buttons": 2, "images": 1, "svgs": 3, "forms": 0, "h1": ["Hero"], "h2": []},
            "element_samples": [{
                "tag": "button",
                "selector_hint": ".cta.primary",
                "text": "Start now",
                "x": 100,
                "y": 200,
                "width": 180,
                "height": 44,
                "display": "inline-flex",
                "position": "static",
                "font_family": "Inter, sans-serif",
                "font_size": "16px",
                "font_weight": "700",
                "color": "rgb(255, 255, 255)",
                "background_color": "rgb(255, 51, 102)",
                "padding": "12px 18px 12px 18px",
                "margin": "0px",
                "border_radius": "8px",
                "box_shadow": "none",
            }],
        }],
    }
    monkeypatch.setattr(
        "routers.brain.visual_snapshot_service.read_snapshot",
        lambda bookmark_id: snapshot if bookmark_id == bm["id"] else None,
    )

    resp = client.post("/api/brain/chat", json={
        "bookmark_id": bm["id"],
        "prompt": "Welche Farben und CTA-Styles nutzt die Seite?",
        "provider_config": {"provider": "ollama", "model": "llama3"},
    })

    assert resp.status_code == 200
    assert "Visual Snapshot" in captured["context"]
    assert "#ff3366" in captured["context"]
    assert "Inter, sans-serif" in captured["context"]
    assert ".cta.primary" in captured["context"]
    assert "radius=8px" in captured["context"]


def test_chat_includes_site_structure_context_for_page_count_questions(client, brain_enabled, monkeypatch):
    captured = {}

    async def fake_scrape(url):
        return {"content": "Page text long enough to become context. " * 8, "title": "Site"}

    async def fake_site_context(bookmark_id, url, force_refresh=False):
        return (
            "## Site Structure (same-origin crawl)\n"
            "Exact discovered/listed page count to report: 4\n"
            "Pages:\n"
            "- / — Home\n"
            "- /kontakt — Kontakt"
        )

    async def fake_ask_llm(prompt, context, provider_config, title="", url="", history=None, language=None):
        captured["context"] = context
        return "Es wurden 4 interne HTML-Seiten gefunden."

    monkeypatch.setattr(scraper_module.scraper_service, "extract_content", fake_scrape)
    monkeypatch.setattr(site_structure_service, "context_for_url", fake_site_context)
    monkeypatch.setattr(llm_module.LLMService, "ask_llm", fake_ask_llm)

    bm = client.post("/api/bookmarks", json={
        "title": "Site",
        "url": "https://example.com",
        "source": "manual",
    }).json()

    resp = client.post("/api/brain/chat", json={
        "bookmark_id": bm["id"],
        "prompt": "Wie viele Seiten hat die Webseite?",
        "provider_config": {"provider": "ollama", "model": "llama3"},
    })

    assert resp.status_code == 200
    assert "Site Structure" in captured["context"]
    assert "Exact discovered/listed page count to report: 4" in captured["context"]


def test_chat_with_german_language_instructs_german_reply(client, brain_enabled, monkeypatch):
    from services.llm_service import LLMService

    async def fake_scrape(url):
        return {"content": "Some page content.", "title": "T"}

    monkeypatch.setattr(scraper_module.scraper_service, "extract_content", fake_scrape)

    captured_system_prompt = {}
    real_build_messages = LLMService._build_messages

    async def fake_ask_llm(prompt, context, provider_config, title="", url="", history=None, language=None):
        messages = real_build_messages(prompt, context, title, url, history, language)
        captured_system_prompt["text"] = messages[0]["content"]
        return "Eine deutsche Antwort."

    monkeypatch.setattr(llm_module.LLMService, "ask_llm", fake_ask_llm)

    bm = client.post("/api/bookmarks", json={
        "title": "T", "url": "https://example.com/de-test", "source": "manual",
    }).json()

    resp = client.post("/api/brain/chat", json={
        "bookmark_id": bm["id"],
        "prompt": "What is this about?",
        "provider_config": {"provider": "ollama", "model": "llama3"},
        "language": "de",
    })

    assert resp.status_code == 200
    assert "Antworte auf Deutsch" in captured_system_prompt["text"]


def test_chat_rescrapes_stale_cache_without_version_marker(client, brain_enabled, monkeypatch):
    """A cache written by an older scraper (no version marker) is re-scraped."""
    scrape_calls = {"n": 0}

    async def fake_scrape(url):
        scrape_calls["n"] += 1
        return {"content": "FRESH content with the answer, plenty long " * 10, "title": "T"}

    async def fake_ask_llm(prompt, context, provider_config, title="", url="", history=None, language=None):
        return context

    monkeypatch.setattr(scraper_module.scraper_service, "extract_content", fake_scrape)
    monkeypatch.setattr(llm_module.LLMService, "ask_llm", fake_ask_llm)

    bm = client.post("/api/bookmarks", json={
        "title": "Site", "url": "https://example.com/page", "source": "manual"}).json()

    # First chat scrapes and persists with the current version marker.
    client.post("/api/brain/chat", json={"bookmark_id": bm["id"], "prompt": "q1",
                "provider_config": {"provider": "ollama", "model": "llama3"}})
    assert scrape_calls["n"] == 1
    # Second chat should NOT re-scrape — the cache now carries the version marker.
    client.post("/api/brain/chat", json={"bookmark_id": bm["id"], "prompt": "q2",
                "provider_config": {"provider": "ollama", "model": "llama3"}})
    assert scrape_calls["n"] == 1
