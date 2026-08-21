import httpx
import pytest

from services.bounded_download import DownloadTooLarge, get_limited


@pytest.mark.asyncio
async def test_get_limited_returns_small_response():
    transport = httpx.MockTransport(
        lambda request: httpx.Response(
            200,
            headers={"content-type": "text/plain; charset=utf-8"},
            content="Grüße".encode(),
        )
    )
    async with httpx.AsyncClient(transport=transport) as client:
        response = await get_limited(client, "https://example.com", max_bytes=100)

    assert response.text == "Grüße"


@pytest.mark.asyncio
async def test_get_limited_rejects_oversized_response():
    transport = httpx.MockTransport(
        lambda request: httpx.Response(200, content=b"01234567890")
    )
    async with httpx.AsyncClient(transport=transport) as client:
        with pytest.raises(DownloadTooLarge):
            await get_limited(client, "https://example.com", max_bytes=10)
