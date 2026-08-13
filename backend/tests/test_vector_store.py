import pytest
import apsw
import sqlite_vec
from unittest.mock import patch, MagicMock

from services import vector_store

FAKE_VEC = [0.1] * 768

@pytest.fixture(autouse=True)
def isolated_vector_store():
    """Provides an isolated, in-memory apsw connection for testing."""
    conn = apsw.Connection(":memory:")
    conn.enableloadextension(True)
    sqlite_vec.load(conn)
    conn.enableloadextension(False)

    with patch("services.vector_store._get_conn", return_value=conn):
        vector_store.reset_table(768)
        yield

def test_upsert_and_count():
    assert vector_store.count() == 0

    success = vector_store.upsert("bm-1", FAKE_VEC)
    assert success is True
    assert vector_store.count() == 1

    # Test update (upsert again)
    vector_store.upsert("bm-1", [0.2] * 768)
    assert vector_store.count() == 1

def test_upsert_empty():
    assert vector_store.upsert("bm-empty", []) is False
    assert vector_store.upsert("bm-none", None) is False

def test_delete():
    vector_store.upsert("bm-1", FAKE_VEC)
    assert vector_store.count() == 1

    vector_store.delete("bm-1")
    assert vector_store.count() == 0

    # Idempotent
    vector_store.delete("bm-1")

def test_delete_many():
    vector_store.upsert("bm-1", FAKE_VEC)
    vector_store.upsert("bm-2", FAKE_VEC)
    vector_store.upsert("bm-3", FAKE_VEC)
    assert vector_store.count() == 3

    vector_store.delete_many(["bm-1", "bm-2"])
    assert vector_store.count() == 1

    vector_store.delete_many([]) # Should do nothing
    assert vector_store.count() == 1

def test_search():
    vector_store.upsert("bm-a", [1.0] + [0.0]*767)
    vector_store.upsert("bm-b", [0.9] + [0.0]*767)

    results = vector_store.search([1.0] + [0.0]*767, k=10)
    assert len(results) == 2
    # First should be bm-a since it's an exact match (closest)
    assert results[0][0] == "bm-a"
    assert results[1][0] == "bm-b"

def test_reset_table_invalid_dim():
    with pytest.raises(ValueError):
        vector_store.reset_table(0)
    with pytest.raises(ValueError):
        vector_store.reset_table(-5)

def test_exceptions_handled():
    # Mock connection to raise exceptions
    conn_mock = MagicMock()
    conn_mock.execute.side_effect = Exception("DB Error")
    # Also handle the reviewer's concern about context manager just in case, though it's not used that way
    conn_mock.__enter__.return_value = conn_mock

    with patch("services.vector_store._get_conn", return_value=conn_mock):
        assert vector_store.upsert("bm-err", FAKE_VEC) is False

        # Should not raise
        vector_store.delete("bm-err")
        vector_store.delete_many(["bm-err"])

        assert vector_store.search(FAKE_VEC, k=5) == []
        assert vector_store.count() == 0
