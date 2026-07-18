from datetime import datetime
from pydantic import BaseModel, Field, field_validator


class TagCreate(BaseModel):
    name: str = Field(min_length=1, max_length=80)
    color: str | None = Field(default=None, max_length=32)

    @field_validator("name")
    @classmethod
    def clean_name(cls, value: str) -> str:
        value = " ".join(value.split())
        if not value:
            raise ValueError("Tag name must not be blank")
        return value


class TagUpdate(BaseModel):
    name: str | None = Field(default=None, min_length=1, max_length=80)
    color: str | None = Field(default=None, max_length=32)

    @field_validator("name")
    @classmethod
    def clean_name(cls, value: str | None) -> str | None:
        if value is None:
            return None
        value = " ".join(value.split())
        if not value:
            raise ValueError("Tag name must not be blank")
        return value


class TagOut(BaseModel):
    id: str
    name: str
    color: str | None
    created_at: datetime
    bookmark_count: int = 0

    model_config = {"from_attributes": True}
