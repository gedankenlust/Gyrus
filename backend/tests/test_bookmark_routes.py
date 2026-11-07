"""The /api/bookmarks API is assembled from three routers (bookmarks,
bookmark_jobs, reader). Starlette matches routes in registration order, so a
static path such as /api/bookmarks/check-links must come before
/api/bookmarks/{bookmark_id}, or it is captured as a bookmark id."""
import pytest
from fastapi.routing import APIRoute
from starlette.routing import compile_path

from routers import bookmarks


def _routes(router=bookmarks.router, prefix=None):
    """(path, methods) in match order, flattening included routers.

    Older FastAPI copies included routes into the parent; newer versions keep
    a lazy placeholder (with `original_router`) at the include position that is
    matched in place. Both preserve registration order. Anything else fails
    loudly so a FastAPI change cannot make these checks pass vacuously.
    """
    prefix = router.prefix if prefix is None else prefix
    for route in router.routes:
        if isinstance(route, APIRoute):
            path = route.path if route.path.startswith(prefix) else prefix + route.path
            yield path, route.methods
        elif getattr(route, "original_router", None) is not None:
            yield from _routes(route.original_router, prefix + route.original_router.prefix)
        else:
            raise AssertionError(f"Unexpected route type {type(route).__name__}")


def test_no_static_bookmark_path_is_shadowed_by_an_earlier_parameter_route():
    routes = list(_routes())
    shadowed = []
    for index, (path, methods) in enumerate(routes):
        if "{" in path:
            continue
        for earlier_path, earlier_methods in routes[:index]:
            if "{" not in earlier_path or not (earlier_methods & methods):
                continue
            regex, _, _ = compile_path(earlier_path)
            if regex.match(path):
                shadowed.append((sorted(methods), path, earlier_path))
    assert not shadowed, shadowed


def test_split_routers_keep_the_bookmarks_prefix_and_paths():
    pairs = [(method, path) for path, methods in _routes() for method in methods]
    expected = {
        ("POST", "/api/bookmarks/check-links"),
        ("GET", "/api/bookmarks/check-links/status"),
        ("POST", "/api/bookmarks/refresh-metadata"),
        ("GET", "/api/bookmarks/refresh-metadata/status"),
        ("POST", "/api/bookmarks/refresh-metadata/cancel"),
        ("POST", "/api/bookmarks/auto-tag-batch"),
        ("GET", "/api/bookmarks/auto-tag-batch/status"),
        ("POST", "/api/bookmarks/auto-tag-batch/cancel"),
        ("POST", "/api/bookmarks/auto-tag-batch/apply"),
        ("DELETE", "/api/bookmarks/auto-tag-batch/draft/{draft_id}"),
        ("POST", "/api/bookmarks/organize-folders"),
        ("GET", "/api/bookmarks/organize-folders/status"),
        ("POST", "/api/bookmarks/organize-folders/cancel"),
        ("POST", "/api/bookmarks/organize-folders/apply"),
        ("DELETE", "/api/bookmarks/organize-folders/draft/{draft_id}"),
        ("GET", "/api/bookmarks/{bookmark_id}/reader"),
        ("POST", "/api/bookmarks/{bookmark_id}/reader/cleanup"),
        ("POST", "/api/bookmarks/{bookmark_id}/reader/translate"),
        ("GET", "/api/bookmarks/{bookmark_id}"),
        ("GET", "/api/bookmarks/count"),
        ("GET", "/api/bookmarks/trash"),
        ("GET", "/api/bookmarks/ids"),
    }
    assert expected <= set(pairs), sorted(expected - set(pairs))
    # Each (method, path) is served by exactly one handler.
    assert len(pairs) == len(set(pairs))


def test_openapi_lists_the_same_bookmark_operations(client):
    """The public schema (what the app was built against) agrees with the
    flattened route list: nothing was lost or duplicated by the split."""
    schema = client.get("/openapi.json").json()["paths"]
    documented = {
        (method.upper(), path)
        for path, operations in schema.items()
        if path.startswith("/api/bookmarks")
        for method in operations
    }
    assert documented == {(method, path) for path, methods in _routes() for method in methods}


@pytest.mark.parametrize("path, key", [
    ("/api/bookmarks/check-links/status", "checked"),
    ("/api/bookmarks/refresh-metadata/status", "processed"),
    ("/api/bookmarks/auto-tag-batch/status", "phase"),
    ("/api/bookmarks/organize-folders/status", "phase"),
])
def test_job_status_paths_reach_the_job_handlers(client, path, key):
    response = client.get(path)
    assert response.status_code == 200
    assert key in response.json()
    assert "running" in response.json()


def test_static_get_paths_are_not_read_as_bookmark_ids(client):
    assert client.get("/api/bookmarks/count").json() == 0
    assert client.get("/api/bookmarks/counts").json() == {"total": 0, "dead": 0, "unread": 0, "trash": 0}
    assert client.get("/api/bookmarks/trash").json() == []
    assert client.get("/api/bookmarks/ids").json() == []
    assert client.get("/api/bookmarks/not-a-bookmark").status_code == 404


def test_cancel_routes_answer_when_no_job_runs(client):
    for path in (
        "/api/bookmarks/refresh-metadata/cancel",
        "/api/bookmarks/auto-tag-batch/cancel",
        "/api/bookmarks/organize-folders/cancel",
    ):
        response = client.post(path)
        assert response.status_code == 200
        assert response.json()["running"] is False
