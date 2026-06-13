import pytest
from sqlalchemy.exc import IntegrityError
from models.collection import Collection

def test_duplicate_inbox_constraint(db):
    # GIVEN: An Inbox collection
    db.add(Collection(name="Inbox"))
    db.commit()
    
    # WHEN: We try to add another one with the same name at root
    # THEN: It should raise an IntegrityError because of our new unique index
    with pytest.raises(IntegrityError):
        db.add(Collection(name="Inbox"))
        db.commit()
    db.rollback()

def test_extension_bookmark_goes_to_inbox(client, db):
    # GIVEN: A bookmark created with source="extension"
    bookmark_data = {
        "title": "Extension Bookmark",
        "url": "https://extension.com",
        "source": "extension"
    }
    
    # WHEN: We post it to the API
    resp = client.post("/api/bookmarks", json=bookmark_data)
    assert resp.status_code == 201
    data = resp.json()
    
    # THEN: It should have a collection_id
    assert data["collection_id"] is not None
    
    # AND: That collection should be named "Inbox"
    inbox = db.query(Collection).filter(Collection.id == data["collection_id"]).first()
    assert inbox is not None
    assert inbox.name == "Inbox"

def test_menubar_bookmark_goes_to_inbox(client, db):
    # GIVEN: A bookmark created via the menu-bar quick-add (source="menubar")
    resp = client.post("/api/bookmarks", json={
        "title": "Menubar Bookmark",
        "url": "https://menubar.com",
        "source": "menubar"
    })
    assert resp.status_code == 201
    data = resp.json()

    # THEN: It is auto-assigned to the Inbox, same as the extension path.
    assert data["collection_id"] is not None
    inbox = db.query(Collection).filter(Collection.id == data["collection_id"]).first()
    assert inbox is not None and inbox.name == "Inbox"


def test_extension_bookmark_reuses_inbox(client, db):
    # GIVEN: One bookmark already in Inbox
    client.post("/api/bookmarks", json={
        "title": "BM1",
        "url": "https://bm1.com",
        "source": "extension"
    })
    
    inbox_count_before = db.query(Collection).filter(Collection.name == "Inbox").count()
    assert inbox_count_before == 1
    
    # WHEN: We post another one
    client.post("/api/bookmarks", json={
        "title": "BM2",
        "url": "https://bm2.com",
        "source": "extension"
    })
    
    # THEN: No new collection should have been created
    inbox_count_after = db.query(Collection).filter(Collection.name == "Inbox").count()
    assert inbox_count_after == 1
