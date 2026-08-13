import pytest
from services import link_check_service
from services.link_check_service import _persist_results
from models.bookmark import Bookmark

def test_persist_results_bulk_update(db, monkeypatch):
    b1 = Bookmark(id="b1", url="http://1", is_dead=False, title="1")
    b2 = Bookmark(id="b2", url="http://2", is_dead=False, title="2")
    b3 = Bookmark(id="b3", url="http://3", is_dead=True, title="3")

    db.add_all([b1, b2, b3])
    db.commit()

    # Mock SessionLocal to use the test db session
    monkeypatch.setattr(link_check_service, "SessionLocal", lambda: db)

    _persist_results([("b1", True), ("b2", False), ("b3", False)])

    # reload
    db.expire_all()

    b1_re = db.query(Bookmark).filter_by(id="b1").first()
    b2_re = db.query(Bookmark).filter_by(id="b2").first()
    b3_re = db.query(Bookmark).filter_by(id="b3").first()

    assert b1_re.is_dead is True
    assert b2_re.is_dead is False
    assert b3_re.is_dead is False
