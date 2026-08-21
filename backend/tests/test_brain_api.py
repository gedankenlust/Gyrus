import pytest
from unittest.mock import patch, MagicMock
from models.bookmark import Bookmark
from services.llm_service import LLMService
from services.scraper_service import scraper_service
from services.brain_sync_service import brain_sync_service
from routers.brain import SCRAPE_MARKER
import os
import shutil

@pytest.fixture
def temp_brain_root(tmp_path):
    root = tmp_path / "gyrus_brain_test"
    root.mkdir()
    original_root = brain_sync_service.root_dir
    original_enabled = brain_sync_service.is_enabled
    brain_sync_service.root_dir = root
    brain_sync_service.is_enabled = True
    yield root
    brain_sync_service.root_dir = original_root
    brain_sync_service.is_enabled = original_enabled

@pytest.mark.asyncio
async def test_chat_with_bookmark_success(client, db, temp_brain_root):
    # 1. Create a bookmark
    bookmark = Bookmark(title="Test Bookmark", url="https://example.com", description="A test site")
    db.add(bookmark)
    db.commit()
    db.refresh(bookmark)

    # 2. Mock external services
    with patch("services.scraper_service.scraper_service.extract_content", new_callable=MagicMock) as mock_scrape, \
         patch("services.llm_service.LLMService.ask_llm", new_callable=MagicMock) as mock_llm:
        
        # We use a helper to make them behave like async functions returning values
        async def async_return(val): return val
        
        mock_scrape.side_effect = lambda *args, **kwargs: async_return({"content": "Example page content", "title": "Test Bookmark", "error": None})
        mock_llm.side_effect = lambda *args, **kwargs: async_return("This is the AI response.")

        # 3. Call the chat endpoint
        response = client.post("/api/brain/chat", json={
            "bookmark_id": bookmark.id,
            "prompt": "Summarize this page"
        })

        # 4. Verify response
        assert response.status_code == 200
        assert response.json()["response"] == "This is the AI response."

        # 5. Verify file creation and content — resolve the path from the service
        # so the test stays correct when the filename scheme changes.
        bookmark_file = brain_sync_service._get_bookmark_file_path(db, bookmark)
        assert bookmark_file.exists()
        
        with open(bookmark_file, "r") as f:
            content = f.read()
            assert "## Content (Scraped)" in content
            assert "Example page content" in content
            assert "## Chat Interaction" in content
            assert "**You:** Summarize this page" in content
            assert "**AI:** This is the AI response." in content

@pytest.mark.asyncio
async def test_chat_with_bookmark_not_found(client):
    response = client.post("/api/brain/chat", json={
        "bookmark_id": "non-existent-id",
        "prompt": "Hello"
    })
    assert response.status_code == 404
    assert response.json()["detail"] == "Bookmark not found"

@pytest.mark.asyncio
async def test_chat_optimization_skips_scraping(client, db, temp_brain_root):
    # 1. Create a bookmark
    bookmark = Bookmark(title="Optimized", url="https://fast.com", description="Already scraped")
    db.add(bookmark)
    db.commit()
    db.refresh(bookmark)

    # 2. Pre-create the file at the exact path the service will look for.
    file_path = brain_sync_service._get_bookmark_file_path(db, bookmark)
    file_path.parent.mkdir(parents=True, exist_ok=True)
    
    long_content = "This is a very long content that should skip the scraping process. " * 10
    # Include the current scrape version marker so this represents an
    # up-to-date cache (older, marker-less caches are intentionally re-scraped).
    file_content = f"""---
title: Optimized
---
## Content (Scraped)
{SCRAPE_MARKER}
{long_content}
"""
    file_path.write_text(file_content)

    # 3. Mock services
    with patch("services.scraper_service.scraper_service.extract_content", new_callable=MagicMock) as mock_scrape, \
         patch("services.llm_service.LLMService.ask_llm", new_callable=MagicMock) as mock_llm:
        
        async def async_return(val): return val
        mock_llm.side_effect = lambda *args, **kwargs: async_return("Optimized response.")

        # 4. Call chat
        response = client.post("/api/brain/chat", json={
            "bookmark_id": bookmark.id,
            "prompt": "What do you see?"
        })

        assert response.status_code == 200
        # 5. Verify scraper was NOT called because header and content were found
        mock_scrape.assert_not_called()
        mock_llm.assert_called_once()

@pytest.mark.asyncio
async def test_update_brain_config(client):
    new_root = "/tmp/new_gyrus_brain"
    response = client.post("/api/brain/config", json={"root_dir": new_root, "is_enabled": True})

    assert response.status_code == 200
    assert response.json()["status"] == "ok"
    # Note: brain_sync_service.root_dir will be resolved, so we check if it ends with the name
    assert response.json()["root_dir"].endswith("new_gyrus_brain")
    assert str(brain_sync_service.root_dir).endswith("new_gyrus_brain")


@pytest.mark.asyncio
async def test_config_accepts_null_root_dir(client):
    # The app pushes config on startup; when no folder is chosen, root_dir is
    # null. This must fall back to the default, not 422.
    resp = client.post("/api/brain/config", json={"root_dir": None, "is_enabled": False})
    assert resp.status_code == 200
    assert resp.json()["is_enabled"] is False
    assert resp.json()["root_dir"].endswith("/.gyrus/brain")


@pytest.mark.asyncio
async def test_config_disabled_does_not_create_dir(client, tmp_path):
    target = tmp_path / "brain_should_not_exist"
    resp = client.post("/api/brain/config", json={"root_dir": str(target), "is_enabled": False})
    assert resp.status_code == 200
    assert not target.exists()  # disabled → no directory litter


def test_get_visual_snapshot_not_found(client):
    bm = client.post("/api/bookmarks", json={
        "title": "Design Ref",
        "url": "https://design.example",
        "source": "manual",
    }).json()

    resp = client.get(f"/api/brain/bookmarks/{bm['id']}/visual-snapshot")

    assert resp.status_code == 404
    assert resp.json()["detail"] == "Visual snapshot not found"


def test_get_visual_snapshot_returns_saved_data(client, monkeypatch):
    bm = client.post("/api/bookmarks", json={
        "title": "Design Ref",
        "url": "https://design.example",
        "source": "manual",
    }).json()
    snapshot = {"bookmark_id": bm["id"], "viewports": [{"name": "desktop"}]}

    monkeypatch.setattr(
        "routers.brain.visual_snapshot_service.read_snapshot",
        lambda bookmark_id: snapshot if bookmark_id == bm["id"] else None,
    )

    resp = client.get(f"/api/brain/bookmarks/{bm['id']}/visual-snapshot")

    assert resp.status_code == 200
    assert resp.json() == snapshot


def test_create_visual_snapshot_uses_bookmark_url(client, monkeypatch):
    captured = {}
    bm = client.post("/api/bookmarks", json={
        "title": "Design Ref",
        "url": "https://design.example",
        "source": "manual",
    }).json()

    async def fake_capture(bookmark_id, url, title=""):
        captured.update({"bookmark_id": bookmark_id, "url": url, "title": title})
        return {"bookmark_id": bookmark_id, "url": url, "title": title, "viewports": []}

    monkeypatch.setattr("routers.brain.visual_snapshot_service.capture_snapshot", fake_capture)

    resp = client.post(f"/api/brain/bookmarks/{bm['id']}/visual-snapshot")

    assert resp.status_code == 200
    assert captured == {"bookmark_id": bm["id"], "url": bm["url"], "title": bm["title"]}
    assert resp.json()["viewports"] == []


def test_create_visual_snapshot_reports_missing_runtime(client, monkeypatch):
    from services.visual_snapshot_service import VisualSnapshotUnavailable

    bm = client.post("/api/bookmarks", json={
        "title": "Design Ref",
        "url": "https://design.example",
        "source": "manual",
    }).json()

    async def fake_capture(*args, **kwargs):
        raise VisualSnapshotUnavailable("Playwright missing")

    monkeypatch.setattr("routers.brain.visual_snapshot_service.capture_snapshot", fake_capture)

    resp = client.post(f"/api/brain/bookmarks/{bm['id']}/visual-snapshot")

    assert resp.status_code == 503
    assert resp.json()["detail"] == "Playwright missing"


def test_start_visual_snapshot_job_returns_pollable_status(client, monkeypatch):
    bm = client.post("/api/bookmarks", json={
        "title": "Design Ref",
        "url": "https://design.example",
        "source": "manual",
    }).json()
    captured = {}

    monkeypatch.setattr(
        "routers.brain.visual_snapshot_job_service.get_status",
        lambda: {"running": False, "bookmark_id": None},
    )

    async def fake_start(bookmark_id, url, title=""):
        captured.update({"bookmark_id": bookmark_id, "url": url, "title": title})
        return {
            "running": True,
            "bookmark_id": bookmark_id,
            "stage": "queued",
            "completed": 0,
            "total": 4,
            "snapshot": None,
            "error": None,
        }

    monkeypatch.setattr("routers.brain.visual_snapshot_job_service.start", fake_start)

    resp = client.post(f"/api/brain/bookmarks/{bm['id']}/visual-snapshot/job")

    assert resp.status_code == 200
    assert resp.json()["running"] is True
    assert resp.json()["total"] == 4
    assert captured == {"bookmark_id": bm["id"], "url": bm["url"], "title": bm["title"]}


def test_visual_snapshot_run_history_is_exposed(client, monkeypatch):
    bm = client.post("/api/bookmarks", json={
        "title": "Design Ref",
        "url": "https://design.example",
        "source": "manual",
    }).json()
    history = [{"run_id": "run-2", "status": "completed", "issue_count": 4}]
    monkeypatch.setattr(
        "routers.brain.visual_snapshot_service.list_snapshot_runs",
        lambda bookmark_id: history if bookmark_id == bm["id"] else [],
    )

    resp = client.get(f"/api/brain/bookmarks/{bm['id']}/visual-snapshot/runs")

    assert resp.status_code == 200
    assert resp.json() == history


def test_get_available_models_success(client, monkeypatch):
    class MockResponse:
        def __init__(self, json_data, status_code=200):
            self._json = json_data
            self.status_code = status_code

        def json(self):
            return self._json

        def raise_for_status(self):
            if self.status_code >= 400:
                import httpx
                raise httpx.HTTPError(f"HTTP {self.status_code}")

    class MockAsyncClient:
        def __init__(self, *args, **kwargs):
            pass

        async def __aenter__(self):
            return self

        async def __aexit__(self, exc_type, exc_val, exc_tb):
            pass

        async def get(self, url, **kwargs):
            if "/api/tags" in url:
                return MockResponse({"models": [{"name": "llama3"}, {"name": "bge-m3"}, {"name": "empty-model"}]})
            return MockResponse({})

        async def post(self, url, json=None, **kwargs):
            if "/api/show" in url:
                model = json.get("model")
                if model == "bge-m3":
                    return MockResponse({"capabilities": ["embedding"]})
                elif model == "llama3":
                    return MockResponse({"capabilities": ["completion", "chat"]})
                else:
                    return MockResponse({})
            return MockResponse({})

    monkeypatch.setattr("routers.brain.httpx.AsyncClient", MockAsyncClient)

    resp = client.get("/api/brain/available-models")
    assert resp.status_code == 200
    data = resp.json()
    assert data["error"] is None
    assert set(data["models"]) == {"llama3", "bge-m3", "empty-model"}
    assert set(data["embedding_models"]) == {"bge-m3"}
    assert set(data["text_models"]) == {"llama3", "empty-model"}


def test_get_available_models_unreachable(client, monkeypatch):
    class MockAsyncClient:
        def __init__(self, *args, **kwargs):
            pass

        async def __aenter__(self):
            return self

        async def __aexit__(self, exc_type, exc_val, exc_tb):
            pass

        async def get(self, url, **kwargs):
            import httpx
            raise httpx.HTTPError("unreachable")

    monkeypatch.setattr("routers.brain.httpx.AsyncClient", MockAsyncClient)

    resp = client.get("/api/brain/available-models")
    assert resp.status_code == 200
    data = resp.json()
    assert "Ollama unreachable" in data["error"]


def test_get_available_models_generic_error(client, monkeypatch):
    class MockAsyncClient:
        def __init__(self, *args, **kwargs):
            pass

        async def __aenter__(self):
            return self

        async def __aexit__(self, exc_type, exc_val, exc_tb):
            pass

        async def get(self, url, **kwargs):
            raise Exception("something weird")

    monkeypatch.setattr("routers.brain.httpx.AsyncClient", MockAsyncClient)

    resp = client.get("/api/brain/available-models")
    assert resp.status_code == 200
    data = resp.json()
    assert "Failed to list models: something weird" in data["error"]
