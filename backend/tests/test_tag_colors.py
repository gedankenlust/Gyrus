"""Tag color assignment: no repeats until the palette is genuinely exhausted."""
from services.tag_colors import PALETTE, next_color, rebalanced
from models.tag import Tag


def test_next_color_never_repeats_within_palette_size(db):
    # Simulate creating one tag per call, same as auto_tag_bookmark does.
    assigned = []
    for i in range(len(PALETTE)):
        c = next_color(db)
        db.add(Tag(name=f"tag{i}", color=c))
        db.flush()
        assigned.append(c)
    assert len(set(assigned)) == len(assigned)  # every color distinct


def test_next_color_keeps_generating_past_palette_size(db):
    # More tags than the curated palette has entries — must still not repeat.
    n = len(PALETTE) + 10
    assigned = []
    for i in range(n):
        c = next_color(db)
        db.add(Tag(name=f"tag{i}", color=c))
        db.flush()
        assigned.append(c)
    assert len(set(assigned)) == n


def test_rebalanced_assigns_every_name_a_distinct_color():
    names = [f"tag{i}" for i in range(len(PALETTE) + 5)]
    colors = rebalanced(names)
    assert len(colors) == len(names)
    assert len(set(colors.values())) == len(names)


def test_create_tag_without_explicit_color_gets_a_distinct_one(client):
    r1 = client.post("/api/tags", json={"name": "one"})
    r2 = client.post("/api/tags", json={"name": "two"})
    assert r1.json()["color"] != r2.json()["color"]


def test_rebalance_endpoint_fixes_collided_colors(client):
    # Force a collision: two tags with the same explicit color, like the old
    # hash scheme could produce.
    client.post("/api/tags", json={"name": "alpha", "color": "#111111"})
    client.post("/api/tags", json={"name": "beta", "color": "#111111"})
    r = client.post("/api/tags/rebalance-colors")
    assert r.status_code == 200
    colors = [t["color"] for t in r.json()]
    assert len(set(colors)) == len(colors)
