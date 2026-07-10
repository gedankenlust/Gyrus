from sqlalchemy.orm import Session

from models.bookmark import BrainMessage


VALID_ROLES = {"user", "assistant"}
VALID_STATUSES = {"complete", "stopped", "error"}


def list_messages(db: Session, bookmark_id: str) -> list[BrainMessage]:
    return (
        db.query(BrainMessage)
        .filter(BrainMessage.bookmark_id == bookmark_id)
        .order_by(BrainMessage.created_at.asc())
        .all()
    )


def add_message(
    db: Session,
    bookmark_id: str,
    role: str,
    content: str,
    model: str | None = None,
    status: str = "complete",
) -> BrainMessage:
    role = role if role in VALID_ROLES else "assistant"
    status = status if status in VALID_STATUSES else "complete"
    msg = BrainMessage(
        bookmark_id=bookmark_id,
        role=role,
        content=content,
        model=model,
        status=status,
    )
    db.add(msg)
    db.commit()
    db.refresh(msg)
    return msg


def clear_messages(db: Session, bookmark_id: str) -> int:
    count = db.query(BrainMessage).filter(BrainMessage.bookmark_id == bookmark_id).count()
    db.query(BrainMessage).filter(BrainMessage.bookmark_id == bookmark_id).delete(
        synchronize_session=False
    )
    db.commit()
    return count
