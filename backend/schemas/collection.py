from datetime import datetime
from pydantic import BaseModel


class CollectionCreate(BaseModel):
    name: str
    parent_id: str | None = None
    icon: str | None = None
    color: str | None = None


class CollectionUpdate(BaseModel):
    name: str | None = None
    parent_id: str | None = None
    icon: str | None = None
    color: str | None = None


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
