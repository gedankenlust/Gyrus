import uuid
from datetime import datetime, timezone
from sqlalchemy import String, DateTime, ForeignKey
from sqlalchemy.orm import Mapped, mapped_column, relationship
from database import Base


class Tag(Base):
    __tablename__ = "tags"

    id: Mapped[str] = mapped_column(String, primary_key=True, default=lambda: str(uuid.uuid4()))
    name: Mapped[str] = mapped_column(String, index=True, unique=True)
    color: Mapped[str | None] = mapped_column(String, nullable=True)

    created_at: Mapped[datetime] = mapped_column(DateTime, default=lambda: datetime.now(timezone.utc))

    bookmark_tags: Mapped[list["BookmarkTag"]] = relationship("BookmarkTag", back_populates="tag", cascade="all, delete-orphan")


class BookmarkTag(Base):
    __tablename__ = "bookmark_tags"

    bookmark_id: Mapped[str] = mapped_column(String, ForeignKey("bookmarks.id"), primary_key=True)
    tag_id: Mapped[str] = mapped_column(String, ForeignKey("tags.id"), primary_key=True)
    source: Mapped[str] = mapped_column(String, nullable=False, default="manual", server_default="manual")

    bookmark: Mapped["Bookmark"] = relationship("Bookmark", back_populates="bookmark_tags")
    tag: Mapped["Tag"] = relationship("Tag", back_populates="bookmark_tags")
