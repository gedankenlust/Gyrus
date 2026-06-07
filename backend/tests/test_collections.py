"""Collection hierarchy: moves must never create a cycle.

A cycle (a folder moved into itself or one of its descendants) would detach
the whole subtree in _build_tree — the folder silently disappears from the
sidebar. The API must reject these moves with a 400.
"""


def _create(client, name, parent_id=None):
    resp = client.post("/api/collections", json={"name": name, "parent_id": parent_id})
    assert resp.status_code == 201
    return resp.json()["id"]


def test_move_folder_into_itself_is_rejected(client):
    a = _create(client, "A")
    resp = client.put(f"/api/collections/{a}", json={"parent_id": a})
    assert resp.status_code == 400


def test_move_folder_into_own_descendant_is_rejected(client):
    a = _create(client, "A")
    b = _create(client, "B", parent_id=a)
    c = _create(client, "C", parent_id=b)
    # Moving A under its grandchild C would form a cycle.
    resp = client.put(f"/api/collections/{a}", json={"parent_id": c})
    assert resp.status_code == 400


def test_valid_move_still_works(client):
    a = _create(client, "A")
    b = _create(client, "B", parent_id=a)
    other = _create(client, "Other")
    # Moving B under an unrelated root is fine.
    resp = client.put(f"/api/collections/{b}", json={"parent_id": other})
    assert resp.status_code == 200
    assert resp.json()["parent_id"] == other


def test_move_to_root_is_allowed(client):
    a = _create(client, "A")
    b = _create(client, "B", parent_id=a)
    # Detaching to the top level (parent_id = null) must not be blocked.
    resp = client.put(f"/api/collections/{b}", json={"parent_id": None})
    assert resp.status_code == 200


def _list_names(client):
    return [c["name"] for c in client.get("/api/collections").json()]


def test_new_folders_keep_creation_order(client):
    _create(client, "First")
    _create(client, "Second")
    _create(client, "Third")
    assert _list_names(client) == ["First", "Second", "Third"]


def test_reorder_changes_order(client):
    a = _create(client, "First")
    b = _create(client, "Second")
    c = _create(client, "Third")
    resp = client.post("/api/collections/reorder",
                       json={"parent_id": None, "ordered_ids": [c, a, b]})
    assert resp.status_code == 200
    assert _list_names(client) == ["Third", "First", "Second"]


def test_reorder_children(client):
    parent = _create(client, "Parent")
    x = _create(client, "X", parent_id=parent)
    y = _create(client, "Y", parent_id=parent)
    client.post("/api/collections/reorder",
                json={"parent_id": parent, "ordered_ids": [y, x]})
    tree = client.get("/api/collections").json()
    p = next(c for c in tree if c["id"] == parent)
    assert [ch["name"] for ch in p["children"]] == ["Y", "X"]


def test_html_export_respects_folder_order(client):
    a = _create(client, "Alpha")
    b = _create(client, "Beta")
    c = _create(client, "Gamma")
    # Reorder: Gamma, Alpha, Beta
    client.post("/api/collections/reorder",
                json={"parent_id": None, "ordered_ids": [c, a, b]})
    html = client.get("/api/export/html").text
    # The folder <H3> headers must appear in the manual order.
    assert html.index("Gamma") < html.index("Alpha") < html.index("Beta")
