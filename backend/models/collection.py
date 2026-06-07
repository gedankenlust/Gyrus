import uuid
from datetime import datetime, timezone
from sqlalchemy import String, ForeignKey, DateTime, Integer, Index, func
from sqlalchemy.orm import Mapped, mapped_column, relationship
from database import Base


class Collection(Base):
    __tablename__ = "collections"

    __table_args__ = (
        Index("idx_collection_name_parent_unique", "name", func.ifnull("parent_id", "root"), unique=True),
    )

    id: Mapped[str] = mapped_column(String, primary_key=True, default=lambda: str(uuid.uuid4()))
    name: Mapped[str] = mapped_column(String, index=True)
    icon: Mapped[str | None] = mapped_column(String, nullable=True)
    color: Mapped[str | None] = mapped_column(String, nullable=True)
    parent_id: Mapped[str | None] = mapped_column(String, ForeignKey("collections.id"), nullable=True)
    # Manual sort order among siblings (same parent). Lower = higher in the list.
    position: Mapped[int] = mapped_column(Integer, default=0, nullable=False)

    created_at: Mapped[datetime] = mapped_column(DateTime, default=lambda: datetime.now(timezone.utc))

    parent: Mapped["Collection | None"] = relationship("Collection", remote_side=[id], back_populates="children")
    children: Mapped[list["Collection"]] = relationship("Collection", back_populates="parent", cascade="all, delete-orphan")
    bookmarks: Mapped[list["Bookmark"]] = relationship("Bookmark", back_populates="collection")
