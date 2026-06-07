import io
import pytest


SIMPLE_HTML = b"""<!DOCTYPE NETSCAPE-Bookmark-file-1>
<META HTTP-EQUIV="Content-Type" CONTENT="text/html; charset=UTF-8">
<TITLE>Bookmarks</TITLE>
<H1>Bookmarks</H1>
<DL><p>
    <DT><A HREF="https://example.com">Example</A>
    <DT><A HREF="https://python.org">Python</A>
</DL>
"""

FOLDER_HTML = b"""<!DOCTYPE NETSCAPE-Bookmark-file-1>
<DL><p>
    <DT><H3>Work</H3>
    <DL><p>
        <DT><A HREF="https://github.com">GitHub</A>
    </DL>
    <DT><A HREF="https://news.ycombinator.com">HN</A>
</DL>
"""


def _upload(client, html: bytes, filename: str = "bookmarks.html"):
    return client.post(
        "/api/import/html",
        files={"file": (filename, io.BytesIO(html), "text/html")},
    )


def test_import_simple(client):
    resp = _upload(client, SIMPLE_HTML)
    assert resp.status_code == 200
    data = resp.json()
    assert data["imported"] == 2
    assert data["skipped"] == 0


def test_import_with_folders(client):
    resp = _upload(client, FOLDER_HTML)
    assert resp.status_code == 200
    data = resp.json()
    assert data["imported"] == 2
    assert data["collections_created"] == 1


def test_import_skips_duplicates(client):
    _upload(client, SIMPLE_HTML)
    resp = _upload(client, SIMPLE_HTML)
    assert resp.status_code == 200
    assert resp.json()["skipped"] == 2
    assert resp.json()["imported"] == 0


def test_import_skips_javascript_urls(client):
    html = b"""<DL><DT><A HREF="javascript:void(0)">Bad</A></DL>"""
    resp = _upload(client, html)
    assert resp.status_code == 200
    assert resp.json()["imported"] == 0


def test_import_merges_folders_by_name(client):
    # Re-importing the same structure must reuse folders, not duplicate them.
    _upload(client, FOLDER_HTML)
    resp = _upload(client, FOLDER_HTML)
    assert resp.status_code == 200
    assert resp.json()["collections_created"] == 0  # "Work" reused
    assert resp.json()["skipped"] == 2              # bookmarks already exist


def test_import_into_named_root_folder(client):
    resp = client.post(
        "/api/import/html",
        files={"file": ("bookmarks.html", io.BytesIO(FOLDER_HTML), "text/html")},
        data={"root_folder_name": "Brave"},
    )
    assert resp.status_code == 200
    # "Brave" wrapper + "Work" inside it
    assert resp.json()["collections_created"] == 2
    assert resp.json()["imported"] == 2


def test_import_separate_root_folders_stay_separate(client):
    client.post(
        "/api/import/html",
        files={"file": ("a.html", io.BytesIO(FOLDER_HTML), "text/html")},
        data={"root_folder_name": "Brave"},
    )
    resp = client.post(
        "/api/import/html",
        files={"file": ("b.html", io.BytesIO(SIMPLE_HTML), "text/html")},
        data={"root_folder_name": "Chrome"},
    )
    assert resp.status_code == 200
    # "Chrome" wrapper created fresh, not merged into "Brave"
    assert resp.json()["collections_created"] == 1
