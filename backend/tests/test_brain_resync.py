"""The AI Brain folder structure must mirror Gyrus: when bookmarks/folders are
renamed or moved, existing markdown files are reconciled to the right path."""
import pytest

from models.bookmark import Bookmark
from models.collection import Collection
from services.brain_sync_service import brain_sync_service


@pytest.fixture
def brain(tmp_path):
    brain_sync_service.update_config(str(tmp_path), True)
    yield brain_sync_service
    brain_sync_service.update_config(None, False)


def test_resync_moves_file_to_current_folder_and_prunes(brain, db):
    # A bookmark that now lives in the "YouTube" collection.
    col = Collection(name="YouTube")
    db.add(col)
    db.commit()
    db.refresh(col)
    bm = Bookmark(title="Clip", url="https://youtu.be/abc", collection_id=col.id)
    db.add(bm)
    db.commit()
    db.refresh(bm)

    # Simulate a stale file left in an old, since-renamed folder.
    stale_dir = brain.root_dir / "ordner1"
    stale_dir.mkdir(parents=True)
    stale_file = stale_dir / "Clip.md"
    stale_file.write_text("---\ntitle: Clip\nurl: https://youtu.be/abc\n---\n\n# Clip\n")

    brain.resync_all(db)

    # The correct path may now include an ID suffix; resolve from the service.
    correct = brain._get_bookmark_file_path(db, bm)
    assert correct.exists()             # moved to the current folder
    assert correct.parent.name == "YouTube"  # in the right collection
    assert not stale_file.exists()      # old copy gone
    assert not stale_dir.exists()       # empty leftover folder pruned


def test_resync_keeps_chat_history_during_move(brain, db):
    bm = Bookmark(title="Note", url="https://example.com/x", collection_id=None)
    db.add(bm)
    db.commit()
    db.refresh(bm)

    old_dir = brain.root_dir / "OldName"
    old_dir.mkdir(parents=True)
    old_file = old_dir / "Note.md"
    old_file.write_text(
        "---\ntitle: Note\nurl: https://example.com/x\n---\n\n# Note\n\n"
        "## Chat Interaction (x)\n**You:** hi\n\n**AI:** hello\n"
    )

    brain.resync_all(db)

    # Resolve the correct path from the service (filename may include ID suffix).
    moved = brain._get_bookmark_file_path(db, bm)
    assert moved.exists()
    assert moved.parent.name == "_Unsorted"
    assert "Chat Interaction" in moved.read_text()
