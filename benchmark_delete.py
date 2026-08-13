import time
import uuid
import os
from sqlalchemy import create_engine
from sqlalchemy.orm import sessionmaker
from backend.database.models import Base, Bookmark, Collection
from backend.services import bookmark_service
from backend.services.brain_sync_service import brain_sync_service
import shutil
import tempfile
from pathlib import Path

# Setup
db_path = tempfile.mktemp(suffix=".sqlite")
engine = create_engine(f"sqlite:///{db_path}")
Base.metadata.create_all(engine)
Session = sessionmaker(bind=engine)
db = Session()

# Setup brain sync
temp_dir = Path(tempfile.mkdtemp())
os.environ["BRAIN_SYNC_DIR"] = str(temp_dir)
brain_sync_service.root_dir = temp_dir
brain_sync_service.is_enabled = True

# Create collections and bookmarks
collections = []
parent_id = None
for i in range(5):
    c_id = str(uuid.uuid4())
    c = Collection(id=c_id, name=f"Collection {i}", parent_id=parent_id)
    db.add(c)
    parent_id = c_id
    collections.append(c)
db.commit()

# Create 500 bookmarks
bm_ids = []
for i in range(500):
    b_id = str(uuid.uuid4())
    b = Bookmark(id=b_id, title=f"Bookmark {i}", url=f"http://example.com/{i}", collection_id=collections[-1].id)
    db.add(b)
    bm_ids.append(b_id)
db.commit()

# Create their files
for bm in db.query(Bookmark).all():
    # skip actual creation, just testing DB query time.
    # Actually wait, _safe_brain_sync will run delete_bookmark_file
    pass

print("Starting benchmark...")
start = time.time()
bookmark_service.delete_bookmarks(db, bm_ids)
end = time.time()

print(f"Deleted 500 bookmarks in {end - start:.4f} seconds")

db.close()
os.remove(db_path)
shutil.rmtree(temp_dir)
