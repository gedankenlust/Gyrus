import uuid
from datetime import datetime, timezone
from sqlalchemy import String, Boolean, DateTime, ForeignKey, Text
from sqlalchemy.orm import Mapped, mapped_column, relationship
from database import Base


class Bookmark(Base):
    __tablename__ = "bookmarks"

    id: Mapped[str] = mapped_column(String, primary_key=True, default=lambda: str(uuid.uuid4()))
    title: Mapped[str] = mapped_column(String, index=True)
    url: Mapped[str] = mapped_column(String, index=True, unique=True)
    description: Mapped[str | None] = mapped_column(Text, nullable=True)
    notes: Mapped[str | None] = mapped_column(Text, nullable=True)
    favicon_path: Mapped[str | None] = mapped_column(String, nullable=True)
    og_image_url: Mapped[str | None] = mapped_column(String, nullable=True)
    og_image_path: Mapped[str | None] = mapped_column(String, nullable=True)
    source: Mapped[str] = mapped_column(String, default="manual")
    is_dead: Mapped[bool] = mapped_column(Boolean, default=False)
    collection_id: Mapped[str | None] = mapped_column(String, ForeignKey("collections.id"), nullable=True)

    created_at: Mapped[datetime] = mapped_column(DateTime, default=lambda: datetime.now(timezone.utc))
    updated_at: Mapped[datetime] = mapped_column(DateTime, default=lambda: datetime.now(timezone.utc), onupdate=lambda: datetime.now(timezone.utc))

    collection: Mapped["Collection | None"] = relationship("Collection", back_populates="bookmarks")
    bookmark_tags: Mapped[list["BookmarkTag"]] = relationship("BookmarkTag", back_populates="bookmark", cascade="all, delete-orphan")
    bookmark_notes: Mapped[list["BookmarkNote"]] = relationship("BookmarkNote", back_populates="bookmark", cascade="all, delete-orphan", order_by="BookmarkNote.created_at.desc()")

    @property
    def tags(self):
        return [bt.tag for bt in self.bookmark_tags]


class BookmarkNote(Base):
    __tablename__ = "bookmark_notes"

    id: Mapped[str] = mapped_column(String, primary_key=True, default=lambda: str(uuid.uuid4()))
    bookmark_id: Mapped[str] = mapped_column(String, ForeignKey("bookmarks.id"), index=True)
    content: Mapped[str] = mapped_column(Text)
    source: Mapped[str] = mapped_column(String, default="user") # "user" or "ai"
    
    created_at: Mapped[datetime] = mapped_column(DateTime, default=lambda: datetime.now(timezone.utc))
    updated_at: Mapped[datetime] = mapped_column(DateTime, default=lambda: datetime.now(timezone.utc), onupdate=lambda: datetime.now(timezone.utc))

    bookmark: Mapped["Bookmark"] = relationship("Bookmark", back_populates="bookmark_notes")
