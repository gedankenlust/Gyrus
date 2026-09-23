"""The local model names folders, and only those names can receive bookmarks."""
from services import folder_organize_service as folders


def test_structure_keeps_one_subfolder_level_and_drops_the_rest():
    parsed = folders.parse_structure(
        "1. Design\n- Schrift\n- Farbe\n- Raster\n- Foto\n- Extra\nVideo\n- YouTube\nNot a folder: this explanation is far too long to be a name\n"
    )
    assert [folder["name"] for folder in parsed] == ["Design", "Video"]
    assert parsed[0]["children"] == ["Schrift", "Farbe", "Raster", "Foto"]
    assert folders.folder_paths(parsed) == [
        "Design", "Design / Schrift", "Design / Farbe", "Design / Raster", "Design / Foto",
        "Video", "Video / YouTube",
    ]


def test_assignments_follow_the_batch_order_and_ignore_unknown_names():
    paths = ["Design", "Design / Schrift", "Video"]
    assigned = folders.parse_assignments("Schrift\nNope\nVideo\n", paths, 3)
    assert assigned == ["Design / Schrift", None, "Video"]


def test_a_header_line_is_ignored_when_the_matches_cover_the_batch():
    paths = ["Design", "Video"]
    assigned = folders.parse_assignments("Allowed folders:\nDesign\nVideo\n", paths, 2)
    assert assigned == ["Design", "Video"]


def test_repeated_links_to_the_same_site_share_one_folder():
    bookmarks = [
        {"id": f"yt{index}", "url": "https://youtu.be/abc" if index % 2 else "https://www.youtube.com/watch?v=abc"}
        for index in range(8)
    ]
    bookmarks += [
        {"id": f"tw{index}", "url": f"https://www.twitch.tv/videos/{index}"}
        for index in range(8)
    ]
    bookmarks += [
        {"id": f"g{index}", "url": "https://www.google.com/search?q=maps"}
        for index in range(8)
    ]
    bookmarks.append({"id": "one", "url": "https://example.com/post"})
    bookmarks += [{"id": f"three{index}", "url": "https://cursor.com/a"} for index in range(3)]
    bookmarks += [{"id": f"two{index}", "url": "https://solo.example/p"} for index in range(2)]
    assigned = folders.link_folders(bookmarks)
    assert {assigned[f"three{index}"] for index in range(3)} == {"Cursor"}
    assert "two0" not in assigned and "two1" not in assigned
    assert {assigned[f"yt{index}"] for index in range(8)} == {"YouTube"}
    assert {assigned[f"tw{index}"] for index in range(8)} == {"Twitch"}
    assert "one" not in assigned
    assert all(not bookmark_id.startswith("g") for bookmark_id in assigned)


def test_place_creates_the_new_folders_and_moves_the_bookmarks(client, db):
    first = client.post("/api/bookmarks", json={
        "title": "Type ramp", "url": "https://type.example", "source": "manual",
    }).json()
    second = client.post("/api/bookmarks", json={
        "title": "A talk", "url": "https://video.example", "source": "manual",
    }).json()
    result = folders.place_bookmarks(db, {
        "Design / Schrift": [first["id"]],
        "Video": [second["id"]],
    })
    assert result["moved"] == 2
    assert result["created"] == 3
    design = next(folder for folder in client.get("/api/collections").json() if folder["name"] == "Design")
    child = next(folder for folder in design["children"] if folder["name"] == "Schrift")
    assert child["parent_id"] == design["id"]
    assert client.get(f"/api/bookmarks/{first['id']}").json()["collection_id"] == child["id"]
