from unittest.mock import AsyncMock, patch

import pytest
from sqlalchemy.orm import sessionmaker

from models.bookmark import Bookmark
from services import bookmark_enrichment_service


def test_new_bookmark_exposes_pending_analysis(client, monkeypatch):
    monkeypatch.setattr(
        "routers.bookmarks.bookmark_enrichment_service.schedule_enrichment",
        lambda bookmark_id, **kwargs: None,
    )
    response = client.post("/api/bookmarks", json={
        "title": "Pending analysis",
        "url": "https://pending-analysis.example",
        "source": "manual",
    })

    assert response.status_code == 201
    analysis = response.json()["analysis"]
    assert analysis["overall"] == "pending"
    assert analysis["metadata"] == "pending"
    assert analysis["reader"] == "pending"
    assert analysis["design"] == "not_requested"


@pytest.mark.asyncio
async def test_enrichment_persists_ready_stages(db, monkeypatch):
    bookmark = Bookmark(
        title="Pipeline",
        url="https://pipeline.example",
        metadata_status="pending",
        reader_status="pending",
    )
    db.add(bookmark)
    db.commit()

    monkeypatch.setattr(
        "services.bookmark_enrichment_service.metadata_service.fetch_metadata",
        AsyncMock(return_value={"description": "Useful page"}),
    )
    monkeypatch.setattr(
        "services.scraper_service.scraper_service.extract_content",
        AsyncMock(return_value={"content": "Readable article text"}),
    )
    monkeypatch.setattr(
        "services.bookmark_service.index_bookmark_embedding",
        AsyncMock(return_value=True),
    )

    # The service uses SessionLocal by design; point it at this fixture's DB.
    PipelineSession = sessionmaker(bind=db.get_bind())
    monkeypatch.setattr("services.bookmark_enrichment_service.SessionLocal", PipelineSession)
    await bookmark_enrichment_service.enrich_bookmark(bookmark.id)

    db.expire_all()
    updated = db.query(Bookmark).filter(Bookmark.id == bookmark.id).one()
    assert updated.metadata_status == "ready"
    assert updated.reader_status == "ready"
    assert updated.index_status == "ready"
    assert updated.scraped_content == "Readable article text"
    assert updated.analysis_attempts == 1


def test_retry_resets_failed_analysis(db, monkeypatch):
    bookmark = Bookmark(
        title="Retry",
        url="https://retry-analysis.example",
        metadata_status="failed",
        reader_status="failed",
        index_status="unavailable",
        analysis_error="network error",
    )
    db.add(bookmark)
    db.commit()
    calls = []
    PipelineSession = sessionmaker(bind=db.get_bind())
    monkeypatch.setattr("services.bookmark_enrichment_service.SessionLocal", PipelineSession)
    monkeypatch.setattr(
        "services.bookmark_enrichment_service.schedule_enrichment",
        lambda bookmark_id, **kwargs: calls.append(bookmark_id),
    )

    assert bookmark_enrichment_service.retry(bookmark.id) is True
    db.expire_all()
    updated = db.query(Bookmark).filter(Bookmark.id == bookmark.id).one()
    assert updated.metadata_status == "pending"
    assert updated.reader_status == "pending"
    assert updated.index_status == "not_requested"
    assert updated.analysis_error is None
    assert calls == [bookmark.id]


def test_unrequested_reader_is_not_reported_as_failure():
    bookmark = Bookmark(
        title="Legacy",
        url="https://legacy-analysis.example",
        metadata_status="ready",
        reader_status="not_requested",
    )
    summary = bookmark_enrichment_service.analysis_summary(
        bookmark, design_captured=False, design_complete=False
    )
    assert summary["overall"] == "not_requested"


def test_successful_reader_stage_clears_stale_error_and_queues_index(db, monkeypatch):
    bookmark = Bookmark(
        title="Recovered",
        url="https://recovered.example",
        metadata_status="ready",
        reader_status="failed",
        index_status="unavailable",
        analysis_error="Reader failed earlier",
        scraped_content="Recovered article text",
    )
    db.add(bookmark)
    db.commit()

    bookmark_enrichment_service.record_stage(
        bookmark.id, "reader", "ready", db=db
    )

    db.refresh(bookmark)
    assert bookmark.reader_status == "ready"
    assert bookmark.index_status == "pending"
    assert bookmark.analysis_error is None


def test_resume_pending_includes_interrupted_index(db, monkeypatch):
    bookmark = Bookmark(
        title="Interrupted index",
        url="https://interrupted-index.example",
        metadata_status="ready",
        reader_status="ready",
        index_status="running",
        scraped_content="Text waiting to be indexed",
    )
    db.add(bookmark)
    db.commit()
    scheduled = []
    PipelineSession = sessionmaker(bind=db.get_bind())
    monkeypatch.setattr("services.bookmark_enrichment_service.SessionLocal", PipelineSession)
    monkeypatch.setattr(
        "services.bookmark_enrichment_service.schedule_enrichment",
        lambda bookmark_id, **kwargs: scheduled.append(bookmark_id),
    )

    assert bookmark_enrichment_service.resume_pending() == 1

    db.expire_all()
    updated = db.query(Bookmark).filter(Bookmark.id == bookmark.id).one()
    assert updated.index_status == "pending"
    assert scheduled == [bookmark.id]


@pytest.mark.asyncio
async def test_enrichment_does_not_mark_reader_ready_when_cache_write_fails(db, monkeypatch):
    bookmark = Bookmark(
        title="Storage failure",
        url="https://storage-failure.example",
        metadata_status="ready",
        reader_status="pending",
    )
    db.add(bookmark)
    db.commit()
    PipelineSession = sessionmaker(bind=db.get_bind())
    monkeypatch.setattr("services.bookmark_enrichment_service.SessionLocal", PipelineSession)
    monkeypatch.setattr(
        "services.scraper_service.scraper_service.extract_content",
        AsyncMock(return_value={"content": "Extracted but not stored"}),
    )
    monkeypatch.setattr(
        "services.bookmark_service.store_scraped_content",
        lambda db, bookmark_id, content: False,
    )
    index = AsyncMock()
    monkeypatch.setattr(
        "services.bookmark_enrichment_service.index_bookmark",
        index,
    )

    await bookmark_enrichment_service.enrich_bookmark(bookmark.id)

    db.expire_all()
    updated = db.query(Bookmark).filter(Bookmark.id == bookmark.id).one()
    assert updated.reader_status == "failed"
    assert "could not be stored" in (updated.analysis_error or "")
    index.assert_not_awaited()
