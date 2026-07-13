from datetime import datetime
from pydantic import BaseModel
from .tag import TagOut


class BookmarkCreate(BaseModel):
    title: str
    url: str
    description: str | None = None
    notes: str | None = None
    collection_id: str | None = None
    tag_ids: list[str] = []
    source: str = "manual"


class BookmarkUpdate(BaseModel):
    title: str | None = None
    url: str | None = None
    description: str | None = None
    notes: str | None = None
    collection_id: str | None = None
    tag_ids: list[str] | None = None
    is_dead: bool | None = None
    is_read: bool | None = None


class BookmarkNoteCreate(BaseModel):
    content: str
    source: str = "user"


class BookmarkNoteOut(BaseModel):
    id: str
    content: str
    source: str
    created_at: datetime
    updated_at: datetime

    model_config = {"from_attributes": True}


class BrainMessageOut(BaseModel):
    id: str
    bookmark_id: str
    role: str
    content: str
    model: str | None = None
    status: str = "complete"
    created_at: datetime

    model_config = {"from_attributes": True}


class BookmarkOut(BaseModel):
    id: str
    title: str
    url: str
    description: str | None
    notes: str | None # Legacy, keeping for compatibility
    bookmark_notes: list[BookmarkNoteOut] = []
    favicon_path: str | None
    og_image_url: str | None
    og_image_path: str | None
    source: str
    is_dead: bool
    is_read: bool = False
    design_snapshot_captured_at: datetime | None = None
    design_snapshot_complete: bool = False
    collection_id: str | None
    tags: list[TagOut] = []
    created_at: datetime
    updated_at: datetime

    model_config = {"from_attributes": True}
