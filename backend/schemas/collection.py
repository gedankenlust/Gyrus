from datetime import datetime
from pydantic import BaseModel, Field, field_validator
from services.collection_validation import MAX_NAME_LENGTH


class CollectionCreate(BaseModel):
    name: str = Field(min_length=1, max_length=MAX_NAME_LENGTH)
    parent_id: str | None = None
    icon: str | None = None
    color: str | None = None

    @field_validator("name")
    @classmethod
    def valid_name(cls, value):
        if not value.strip():
            raise ValueError("Folder name must not be blank")
        return value.strip()


class CollectionUpdate(BaseModel):
    name: str | None = Field(default=None, min_length=1, max_length=MAX_NAME_LENGTH)
    parent_id: str | None = None
    icon: str | None = None
    color: str | None = None

    @field_validator("name")
    @classmethod
    def valid_name(cls, value):
        if value is None or not value.strip():
            raise ValueError("Folder name must not be blank")
        return value.strip()


class CollectionOut(BaseModel):
    id: str
    name: str
    parent_id: str | None
    icon: str | None
    color: str | None = None
    created_at: datetime
    bookmark_count: int = 0
    children: list["CollectionOut"] = []

    model_config = {"from_attributes": True}


CollectionOut.model_rebuild()
