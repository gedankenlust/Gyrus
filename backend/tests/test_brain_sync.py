import os
import shutil
import pytest
from pathlib import Path
from sqlalchemy import create_engine
from sqlalchemy.orm import sessionmaker
from models.bookmark import Bookmark
from models.collection import Collection
from database import Base
from services.brain_sync_service import BrainSyncService

# Setup test database
SQLALCHEMY_DATABASE_URL = "sqlite:///:memory:"
engine = create_engine(SQLALCHEMY_DATABASE_URL, connect_args={"check_same_thread": False})
TestingSessionLocal = sessionmaker(autocommit=False, autoflush=False, bind=engine)

@pytest.fixture
def db():
    Base.metadata.create_all(bind=engine)
    db = TestingSessionLocal()
    try:
        yield db
    finally:
        db.close()
        Base.metadata.drop_all(bind=engine)

@pytest.fixture
def brain_service(tmp_path):
    # Use a temporary directory for the brain root
    return BrainSyncService(root_dir=str(tmp_path))

def test_sanitize_name(brain_service):
    assert brain_service._sanitize_name("Valid Name") == "Valid Name"
    assert brain_service._sanitize_name("Name with / slash") == "Name with _ slash"
    assert brain_service._sanitize_name("Illegal: *?<>|") == "Illegal_ _____"

def test_get_collection_path(db, brain_service):
    # Setup collection hierarchy: Root -> Parent -> Child
    root = Collection(name="Root")
    db.add(root)
    db.flush()
    
    parent = Collection(name="Parent", parent_id=root.id)
    db.add(parent)
    db.flush()
    
    child = Collection(name="Child", parent_id=parent.id)
    db.add(child)
    db.flush()
    
    path = brain_service._get_collection_path(db, child.id)
    assert path == Path("Root/Parent/Child")

def test_sync_bookmark_creation(db, brain_service):
    bookmark = Bookmark(
        title="Test Bookmark",
        url="https://example.com",
        description="A test description"
    )
    db.add(bookmark)
    db.flush()
    
    brain_service.sync_bookmark(db, bookmark)

    expected_path = brain_service.root_dir / "_Unsorted" / "Test Bookmark.md"
    assert expected_path.exists()
    with open(expected_path, "r") as f:
        content = f.read()
        assert "title: Test Bookmark" in content
        assert "url: https://example.com" in content
        assert "# Test Bookmark" in content
        assert "A test description" in content

def test_sync_bookmark_move(db, brain_service):
    # 1. Create in root
    bookmark = Bookmark(title="Moving Day", url="https://move.me")
    db.add(bookmark)
    db.flush()
    
    brain_service.sync_bookmark(db, bookmark)
    old_file_path = brain_service.root_dir / "_Unsorted" / "Moving Day.md"
    assert old_file_path.exists()
    
    # 2. Move to collection
    folder = Collection(name="New Home")
    db.add(folder)
    db.flush()
    
    # Capture old path
    old_path = brain_service._get_bookmark_file_path(db, bookmark)
    
    bookmark.collection_id = folder.id
    db.flush()
    
    brain_service.sync_bookmark(db, bookmark, old_path=old_path)
    
    new_file_path = brain_service.root_dir / "New Home" / "Moving Day.md"
    assert new_file_path.exists()
    assert not old_file_path.exists()

def test_delete_bookmark_file(db, brain_service):
    bookmark = Bookmark(title="Delete Me", url="https://gone.soon")
    db.add(bookmark)
    db.flush()
    
    brain_service.sync_bookmark(db, bookmark)
    file_path = brain_service.root_dir / "_Unsorted" / "Delete Me.md"
    assert file_path.exists()
    
    brain_service.delete_bookmark_file(db, bookmark)
    assert not file_path.exists()

def test_sync_bookmark_non_destructive(db, brain_service):
    # 1. Create file with existing content
    bookmark = Bookmark(title="Existing", url="https://already.there")
    db.add(bookmark)
    db.flush()
    
    file_path = brain_service.root_dir / "Existing.md"
    file_path.write_text("Preserve me!")
    
    # 2. Call sync_bookmark
    brain_service.sync_bookmark(db, bookmark)
    
    # 3. Verify content was NOT overwritten
    assert file_path.read_text() == "Preserve me!"
