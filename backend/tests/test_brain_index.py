"""The AI Brain keeps an auto-generated _Index.md listing all bookmarks."""
import pytest

from models.bookmark import Bookmark
from models.collection import Collection
from services.brain_sync_service import brain_sync_service


@pytest.fixture
def brain(tmp_path):
    brain_sync_service.update_config(str(tmp_path), True)
    yield brain_sync_service
    brain_sync_service.update_config(None, False)


def test_index_lists_all_bookmarks_grouped_by_folder(brain, db):
    col = Collection(name="YouTube")
    db.add(col)
    db.commit()
    db.refresh(col)
    db.add(Bookmark(title="Clip", url="https://youtu.be/abc", collection_id=col.id))
    db.add(Bookmark(title="Loose", url="https://example.com/x", collection_id=None))
    db.commit()

    brain.rebuild_index(db, force=True)

    index = (brain.root_dir / "_Index.md").read_text()
    assert "# Gyrus Index" in index
    assert "2 bookmarks" in index
    assert "## YouTube (1)" in index
    assert "## Unsorted (1)" in index
    assert "https://youtu.be/abc" in index
    assert "[Clip]" in index            # links to the (would-be) markdown file
    assert "https://example.com/x" in index


def test_index_includes_tags(brain, db):
    from models.tag import Tag, BookmarkTag
    bm = Bookmark(title="Tagged", url="https://example.com/t", collection_id=None)
    tag = Tag(name="money", color="#0f0")
    db.add(bm); db.add(tag); db.commit(); db.refresh(bm); db.refresh(tag)
    db.add(BookmarkTag(bookmark_id=bm.id, tag_id=tag.id)); db.commit()

    brain.rebuild_index(db, force=True)
    index = (brain.root_dir / "_Index.md").read_text()
    assert "#money" in index
