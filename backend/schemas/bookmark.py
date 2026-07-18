from datetime import datetime
from pydantic import BaseModel, Field, field_validator
from .tag import TagOut
from services.outbound_url_security import validate_bookmark_url_syntax


class BookmarkCreate(BaseModel):
    title: str = Field(min_length=1, max_length=1000)
    url: str = Field(min_length=8, max_length=8192)
    description: str | None = Field(default=None, max_length=20_000)
    notes: str | None = Field(default=None, max_length=100_000)
    collection_id: str | None = None
    tag_ids: list[str] = Field(default_factory=list, max_length=200)
    source: str = Field(default="manual", max_length=32)

    @field_validator("url")
    @classmethod
    def valid_url(cls, value: str) -> str:
        return validate_bookmark_url_syntax(value)


class BookmarkUpdate(BaseModel):
    title: str | None = Field(default=None, min_length=1, max_length=1000)
    url: str | None = Field(default=None, min_length=8, max_length=8192)
    description: str | None = Field(default=None, max_length=20_000)
    notes: str | None = Field(default=None, max_length=100_000)
    collection_id: str | None = None
    tag_ids: list[str] | None = None
    is_dead: bool | None = None
    is_read: bool | None = None

    @field_validator("url")
    @classmethod
    def valid_url(cls, value: str | None) -> str | None:
        return validate_bookmark_url_syntax(value) if value is not None else None


class BookmarkNoteCreate(BaseModel):
    content: str = Field(min_length=1, max_length=100_000)
    source: str = Field(default="user", max_length=32)


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
