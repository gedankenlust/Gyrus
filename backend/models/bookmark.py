import uuid
from datetime import datetime, timezone
from sqlalchemy import String, Boolean, DateTime, ForeignKey, Text, Integer
from sqlalchemy.orm import Mapped, mapped_column, relationship
from database import Base


class Bookmark(Base):
    __tablename__ = "bookmarks"

    id: Mapped[str] = mapped_column(String, primary_key=True, default=lambda: str(uuid.uuid4()))
    title: Mapped[str] = mapped_column(String, index=True)
    url: Mapped[str] = mapped_column(String, index=True, unique=True)
    description: Mapped[str | None] = mapped_column(Text, nullable=True)
    notes: Mapped[str | None] = mapped_column(Text, nullable=True)
    # Extracted page text, cached when a bookmark's reader/chat is opened, so
    # full-text search can match words from the article body (not just title/url).
    scraped_content: Mapped[str | None] = mapped_column(Text, nullable=True)
    favicon_path: Mapped[str | None] = mapped_column(String, nullable=True)
    og_image_url: Mapped[str | None] = mapped_column(String, nullable=True)
    og_image_path: Mapped[str | None] = mapped_column(String, nullable=True)
    source: Mapped[str] = mapped_column(String, default="manual")
    is_dead: Mapped[bool] = mapped_column(Boolean, default=False)
    is_read: Mapped[bool] = mapped_column(Boolean, default=False, nullable=False, server_default="0")
    # Durable enrichment state lets interrupted work resume after app restarts.
    metadata_status: Mapped[str] = mapped_column(String, default="pending", nullable=False, server_default="pending")
    reader_status: Mapped[str] = mapped_column(String, default="pending", nullable=False, server_default="pending")
    index_status: Mapped[str] = mapped_column(String, default="not_requested", nullable=False, server_default="not_requested")
    analysis_error: Mapped[str | None] = mapped_column(Text, nullable=True)
    analysis_attempts: Mapped[int] = mapped_column(Integer, default=0, nullable=False, server_default="0")
    analysis_updated_at: Mapped[datetime | None] = mapped_column(DateTime, nullable=True)
    collection_id: Mapped[str | None] = mapped_column(String, ForeignKey("collections.id"), nullable=True)

    # Soft-delete: when set, the bookmark is in the Trash (hidden from all normal
    # views) and is purged for good after TRASH_RETENTION_DAYS.
    deleted_at: Mapped[datetime | None] = mapped_column(DateTime, nullable=True, index=True)

    created_at: Mapped[datetime] = mapped_column(DateTime, default=lambda: datetime.now(timezone.utc))
    updated_at: Mapped[datetime] = mapped_column(DateTime, default=lambda: datetime.now(timezone.utc), onupdate=lambda: datetime.now(timezone.utc))

    collection: Mapped["Collection | None"] = relationship("Collection", back_populates="bookmarks")
    bookmark_tags: Mapped[list["BookmarkTag"]] = relationship("BookmarkTag", back_populates="bookmark", cascade="all, delete-orphan")
    bookmark_notes: Mapped[list["BookmarkNote"]] = relationship("BookmarkNote", back_populates="bookmark", cascade="all, delete-orphan", order_by="BookmarkNote.created_at.desc()")
    brain_messages: Mapped[list["BrainMessage"]] = relationship("BrainMessage", back_populates="bookmark", cascade="all, delete-orphan", order_by="BrainMessage.created_at.asc()")

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


class BrainMessage(Base):
    __tablename__ = "brain_messages"

    id: Mapped[str] = mapped_column(String, primary_key=True, default=lambda: str(uuid.uuid4()))
    bookmark_id: Mapped[str] = mapped_column(String, ForeignKey("bookmarks.id", ondelete="CASCADE"), index=True)
    role: Mapped[str] = mapped_column(String, nullable=False)  # "user" or "assistant"
    content: Mapped[str] = mapped_column(Text, nullable=False)
    model: Mapped[str | None] = mapped_column(String, nullable=True)
    status: Mapped[str] = mapped_column(String, nullable=False, default="complete")  # complete, stopped, error
    created_at: Mapped[datetime] = mapped_column(DateTime, default=lambda: datetime.now(timezone.utc), index=True)

    bookmark: Mapped["Bookmark"] = relationship("Bookmark", back_populates="brain_messages")
