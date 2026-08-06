from datetime import datetime, timedelta, timezone
from services import brain_chat_service

def test_list_messages_empty(client, db):
    bm = client.post("/api/bookmarks", json={"title": "Test 1", "url": "https://example1.com"}).json()
    messages = brain_chat_service.list_messages(db, bm["id"])
    assert messages == []

def test_list_messages_filtering(client, db):
    bm1 = client.post("/api/bookmarks", json={"title": "Test 1", "url": "https://example1.com"}).json()
    bm2 = client.post("/api/bookmarks", json={"title": "Test 2", "url": "https://example2.com"}).json()

    brain_chat_service.add_message(db, bm1["id"], "user", "msg1 for bm1")
    brain_chat_service.add_message(db, bm2["id"], "user", "msg1 for bm2")
    brain_chat_service.add_message(db, bm1["id"], "assistant", "msg2 for bm1")

    messages_bm1 = brain_chat_service.list_messages(db, bm1["id"])
    assert len(messages_bm1) == 2
    assert messages_bm1[0].content == "msg1 for bm1"
    assert messages_bm1[1].content == "msg2 for bm1"

    messages_bm2 = brain_chat_service.list_messages(db, bm2["id"])
    assert len(messages_bm2) == 1
    assert messages_bm2[0].content == "msg1 for bm2"

def test_list_messages_ordering(client, db):
    bm = client.post("/api/bookmarks", json={"title": "Test 1", "url": "https://example1.com"}).json()

    msg1 = brain_chat_service.add_message(db, bm["id"], "user", "first")
    msg2 = brain_chat_service.add_message(db, bm["id"], "assistant", "second")
    msg3 = brain_chat_service.add_message(db, bm["id"], "user", "third")

    # Modify timestamps so they are completely out of order compared to insertion
    now = datetime.now(timezone.utc)
    msg1.created_at = now
    msg2.created_at = now - timedelta(days=2)
    msg3.created_at = now - timedelta(days=1)
    db.commit()

    messages = brain_chat_service.list_messages(db, bm["id"])
    assert len(messages) == 3
    assert messages[0].content == "second"
    assert messages[1].content == "third"
    assert messages[2].content == "first"
