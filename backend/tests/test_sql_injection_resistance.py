"""Regression coverage for request data reaching SQLite query paths.

These tests do not attempt to exploit the local application. They verify that
SQL-looking input remains data, that malformed FTS syntax does not become a
server error, and that dynamic list/sort endpoints leave the database intact.
"""

import pytest


BASE_BOOKMARK = {
    "title": "SQL safety baseline",
    "url": "https://example.com/sql-safety-baseline",
    "source": "manual",
}


@pytest.mark.parametrize(
    "query",
    [
        "' OR 1=1 --",
        '"; DROP TABLE bookmarks; --',
        '" OR "1"="1',
        "NEAR(unclosed",
        "* OR *",
        "%_'\";--",
    ],
)
def test_sql_like_search_input_is_harmless(client, query):
    baseline = client.post("/api/bookmarks", json=BASE_BOOKMARK)
    assert baseline.status_code == 201

    response = client.get("/api/search", params={"q": query})

    assert response.status_code == 200
    assert isinstance(response.json(), list)

    # A subsequent write proves that a payload did not alter or remove the
    # bookmarks table, while the original row proves existing data survived.
    follow_up = client.post(
        "/api/bookmarks",
        json={
            "title": "Still writable",
            "url": f"https://example.com/still-writable-{abs(hash(query))}",
            "source": "manual",
        },
    )
    assert follow_up.status_code == 201
    bookmark_ids = {item["id"] for item in client.get("/api/bookmarks").json()}
    assert baseline.json()["id"] in bookmark_ids
    assert follow_up.json()["id"] in bookmark_ids


def test_sql_like_values_remain_data_in_bookmarks_and_tags(client):
    title = "Research'); DROP TABLE tags; --"
    tag_name = "security' OR '1'='1"

    bookmark = client.post(
        "/api/bookmarks",
        json={
            "title": title,
            "url": "https://example.com/sql-looking-title",
            "source": "manual",
        },
    )
    tag = client.post("/api/tags", json={"name": tag_name})

    assert bookmark.status_code == 201
    assert bookmark.json()["title"] == title
    assert tag.status_code == 201
    assert tag.json()["name"] == tag_name

    assert any(item["id"] == bookmark.json()["id"] for item in client.get("/api/bookmarks").json())
    assert any(item["id"] == tag.json()["id"] for item in client.get("/api/tags").json())


@pytest.mark.parametrize(
    "params",
    [
        {"sort_by": "created_at; DROP TABLE bookmarks; --"},
        {"sort_by": "title", "order": "desc; DELETE FROM tags; --"},
        {"tag": "' OR 1=1 --"},
    ],
)
def test_sql_like_list_parameters_do_not_change_the_database(client, params):
    baseline = client.post("/api/bookmarks", json=BASE_BOOKMARK)
    assert baseline.status_code == 201

    response = client.get("/api/bookmarks", params=params)

    assert response.status_code == 200
    bookmark_ids = {item["id"] for item in client.get("/api/bookmarks").json()}
    assert baseline.json()["id"] in bookmark_ids
