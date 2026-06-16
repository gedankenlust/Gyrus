from datetime import datetime
from pydantic import BaseModel


class TagCreate(BaseModel):
    name: str
    color: str | None = None


class TagUpdate(BaseModel):
    name: str | None = None
    color: str | None = None


class TagOut(BaseModel):
    id: str
    name: str
    color: str | None
    created_at: datetime
    bookmark_count: int = 0

    model_config = {"from_attributes": True}
