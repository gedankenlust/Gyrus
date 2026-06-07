"""Tests for: URL normalization (dedup), import folder order, note search."""
import io

from services.url_utils import normalize_url


# --- 1. URL normalization -------------------------------------------------

def test_normalize_strips_tracking_and_trailing_slash():
    assert normalize_url("https://example.com/page/?utm_source=news&id=7") == \
        "https://example.com/page?id=7"
    assert normalize_url("HTTPS://Example.com/Page/") == "https://example.com/Page"
    assert normalize_url("https://x.com/?fbclid=abc") == "https://x.com"


def test_normalize_keeps_functional_params():
    assert normalize_url("https://youtube.com/watch?v=abc&utm_source=x") == \
        "https://youtube.com/watch?v=abc"


def test_create_dedupes_near_duplicate_urls(client):
    a = client.post("/api/bookmarks", json={
        "title": "A", "url": "https://example.com/p?utm_source=tw", "source": "manual"})
    assert a.status_code == 201
    # Same page, only tracking + trailing slash differ → duplicate.
    b = client.post("/api/bookmarks", json={
        "title": "B", "url": "https://example.com/p/", "source": "manual"})
    assert b.status_code == 409


# --- 2. Import preserves folder order via position ------------------------

MULTI_FOLDER_HTML = b"""<!DOCTYPE NETSCAPE-Bookmark-file-1>
<DL><p>
    <DT><H3>Zebra</H3>
    <DL><p><DT><A HREF="https://z.example.com">Z</A></DL>
    <DT><H3>Apple</H3>
    <DL><p><DT><A HREF="https://a.example.com">A</A></DL>
    <DT><H3>Mango</H3>
    <DL><p><DT><A HREF="https://m.example.com">M</A></DL>
</DL>
"""


def test_import_preserves_folder_order(client):
    client.post("/api/import/html",
                files={"file": ("b.html", io.BytesIO(MULTI_FOLDER_HTML), "text/html")})
    names = [c["name"] for c in client.get("/api/collections").json()]
    assert names == ["Zebra", "Apple", "Mango"]  # import order, not alphabetical


def test_import_dedupes_tracking_params(client):
    html = b"""<DL><DT><A HREF="https://dup.example.com/?utm_source=a">One</A>
                   <DT><A HREF="https://dup.example.com/">Two</A></DL>"""
    resp = client.post("/api/import/html",
                       files={"file": ("d.html", io.BytesIO(html), "text/html")})
    assert resp.json()["imported"] == 1
    assert resp.json()["skipped"] == 1


# --- 3. Structured notes are searchable -----------------------------------

def test_search_finds_bookmark_by_note_content(client):
    bm = client.post("/api/bookmarks", json={
        "title": "Plain Title", "url": "https://noteme.example.com", "source": "manual"}).json()
    client.post(f"/api/bookmarks/{bm['id']}/notes",
                json={"content": "remember the quokka detail", "source": "user"})
    results = client.get("/api/search", params={"q": "quokka"}).json()
    assert any(r["id"] == bm["id"] for r in results)


def test_search_finds_bookmark_by_tag_name(client):
    tag = client.post("/api/tags", json={"name": "synthwave", "color": "#abcdef"}).json()
    bm = client.post("/api/bookmarks", json={
        "title": "Unrelated Title", "url": "https://tagme.example.com",
        "source": "manual", "tag_ids": [tag["id"]]}).json()
    results = client.get("/api/search", params={"q": "synthwave"}).json()
    assert any(r["id"] == bm["id"] for r in results)


def test_sort_by_favicon_groups_same_site(client, db):
    # "Group by favicon" sorts by the URL host, so same-site bookmarks cluster
    # regardless of whether their favicon has been fetched yet. www. is stripped.
    from models.bookmark import Bookmark
    db.add_all([
        Bookmark(title="A1", url="https://www.shop.com/1", favicon_path="aaa.ico"),
        Bookmark(title="B1", url="https://blog.com/1", favicon_path="bbb.ico"),
        Bookmark(title="A2", url="https://shop.com/2", favicon_path=None),  # same host, no favicon yet
    ])
    db.commit()
    results = client.get("/api/bookmarks", params={"sort_by": "favicon", "order": "asc"}).json()
    hosts = [r["url"].split("/")[2].removeprefix("www.") for r in results]
    # blog.com < shop.com → the two shop.com entries are adjacent at the end,
    # even though one has no favicon.
    assert hosts == ["blog.com", "shop.com", "shop.com"]
