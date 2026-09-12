import asyncio

import pytest
from sqlalchemy import create_engine, inspect
from sqlalchemy.orm import sessionmaker

from database import Base
from models.bookmark import Bookmark
from routers import bookmarks
from services import bookmark_service, bookmark_response_service


@pytest.mark.asyncio
async def test_slow_favicons_leave_single_db_connection_free_for_pagination(tmp_path, monkeypatch):
    engine = create_engine(f"sqlite:///{tmp_path/'scroll.db'}", pool_size=1,
                           max_overflow=0, pool_timeout=0.1,
                           connect_args={'check_same_thread':False})
    Base.metadata.create_all(engine)
    sessions = sessionmaker(bind=engine)
    with sessions() as db:
        db.add_all([Bookmark(id=str(i), title='Example', url=f'https://example.com/{i}') for i in range(20)])
        db.commit()
    release = asyncio.Event()
    started = asyncio.Event()
    active = peak = 0
    async def slow_fetch(_):
        nonlocal active, peak
        active += 1
        peak = max(peak, active)
        if active == 3:
            started.set()
        try:
            await release.wait()
            return {'description':'Cached metadata'}
        finally:
            active -= 1
    monkeypatch.setattr(bookmarks, '_metadata_fetch_slots', asyncio.Semaphore(3))
    monkeypatch.setattr(bookmarks.metadata_service, 'fetch_metadata', slow_fetch)
    async def fetch(id_):
        with sessions() as db:
            return await bookmarks.fetch_meta(id_, db)
    tasks = [asyncio.create_task(fetch(str(i))) for i in range(12)]
    try:
        await asyncio.wait_for(started.wait(), 2)
        assert engine.pool.checkedout() == 0
        # Real list serialization must remain possible while all three websites hang.
        with sessions() as db:
            page = bookmarks.list_bookmarks(limit=10, offset=10, db=db)
            assert len(page) == 10
        release.set()
        results = await asyncio.wait_for(asyncio.gather(*tasks), 5)
        assert len(results) == 12
        assert peak == 3
        assert engine.pool.checkedout() == 0
    finally:
        release.set()
        for task in tasks:
            if not task.done(): task.cancel()
        await asyncio.gather(*tasks, return_exceptions=True)
        engine.dispose()


def test_list_summary_does_not_load_reader_text_or_private_notes(db):
    db.add(Bookmark(id='large', title='Example', url='https://example.com',
                    scraped_content='Large reader content ' * 10000, notes='Private notes ' * 10000))
    db.commit()
    db.expunge_all()
    bm = bookmark_service.get_bookmarks(db)[0]
    assert {'scraped_content', 'notes'} <= inspect(bm).unloaded
    summary = bookmark_response_service.enrich_bookmark_summary(bm)
    assert summary.id == 'large'
    assert {'scraped_content', 'notes'} <= inspect(bm).unloaded


@pytest.mark.asyncio
async def test_metadata_response_does_not_overwrite_edited_bookmark(db, monkeypatch):
    db.add(Bookmark(id='changing', title='Example', url='https://example.com/old'))
    db.commit()
    async def fetch(_):
        bm = bookmark_service.get_bookmark(db, 'changing')
        bm.url = 'https://example.com/new'
        bm.description = 'New metadata'
        db.commit()
        return {'description':'Stale metadata'}
    monkeypatch.setattr(bookmarks.metadata_service, 'fetch_metadata', fetch)
    from fastapi import HTTPException
    with pytest.raises(HTTPException) as error:
        await bookmarks.fetch_meta('changing', db)
    assert error.value.status_code == 409
    assert bookmark_service.get_bookmark(db, 'changing').description == 'New metadata'


@pytest.mark.asyncio
async def test_cancelled_favicon_releases_slot_and_records_retryable_failure(db, monkeypatch):
    db.add(Bookmark(id='cancel', title='Example', url='https://example.com/cancel'))
    db.commit()
    entered = asyncio.Event()
    async def fetch(_):
        entered.set()
        await asyncio.Event().wait()
    gate = asyncio.Semaphore(1)
    monkeypatch.setattr(bookmarks, '_metadata_fetch_slots', gate)
    monkeypatch.setattr(bookmarks.metadata_service, 'fetch_metadata', fetch)
    task = asyncio.create_task(bookmarks.fetch_meta('cancel', db))
    try:
        await asyncio.wait_for(entered.wait(), 1)
        assert not db.in_transaction()
    finally:
        task.cancel()
        await asyncio.gather(task, return_exceptions=True)
    assert not gate.locked()
    assert bookmark_service.get_bookmark(db, 'cancel').metadata_status == 'failed'
