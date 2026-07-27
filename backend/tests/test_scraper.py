import json

import pytest
import httpx
from bs4 import BeautifulSoup
from unittest.mock import AsyncMock, patch
from services.scraper_service import (
    ScraperRequestError,
    _extract_jsonld_facts,
    _fetch_text,
    scraper_service,
)

@pytest.mark.asyncio
async def test_extract_content_success():
    html_content = """
    <html>
        <head><title>Test Page</title></head>
        <body>
            <h1>Main Title</h1>
            <div id="content">
                <p>This is the main content that readability should find.</p>
                <h2>Subheading</h2>
                <p>More interesting text here.</p>
            </div>
        </body>
    </html>
    """
    
    with patch(
        "services.scraper_service._fetch_text",
        new_callable=AsyncMock,
        return_value=html_content,
    ):
        result = await scraper_service.extract_content("https://example.com")
        
        assert result["error"] is None
        # readability-lxml might extract "Test Page" or "Main Title" depending on implementation
        assert result["title"] in ["Test Page", "Main Title"]
        assert "readability should find" in result["content"]
        assert "h1: Main Title" in result["structural_summary"]
        assert "h2: Subheading" in result["structural_summary"]

@pytest.mark.asyncio
async def test_extract_content_failure():
    with patch(
        "services.scraper_service._fetch_text",
        new_callable=AsyncMock,
        side_effect=RuntimeError("Website returned HTTP 404"),
    ):
        result = await scraper_service.extract_content("https://example.com/404")
        
        assert result["error"] is not None
        assert result["content"] == ""

@pytest.mark.asyncio
async def test_fetch_text_rejects_non_text_payload():
    transport = httpx.MockTransport(
        lambda request: httpx.Response(
            200,
            headers={"content-type": "application/pdf"},
            content=b"%PDF",
        )
    )
    async with httpx.AsyncClient(transport=transport) as client:
        with pytest.raises(ScraperRequestError, match="Unsupported content type"):
            await _fetch_text(client, "https://example.com/file.pdf")


@pytest.mark.asyncio
async def test_fetch_text_enforces_decoded_size_limit():
    transport = httpx.MockTransport(
        lambda request: httpx.Response(
            200,
            headers={"content-type": "text/html; charset=utf-8"},
            content=b"01234567890",
        )
    )
    async with httpx.AsyncClient(transport=transport) as client:
        with pytest.raises(ScraperRequestError, match="safety limit"):
            await _fetch_text(client, "https://example.com", max_bytes=10)


@pytest.mark.asyncio
async def test_get_pagespeed_metrics_success():
    mock_data = {
        "loadingExperience": {
            "metrics": {
                "LARGEST_CONTENTFUL_PAINT_MS": {"percentile": 1200},
                "CUMULATIVE_LAYOUT_SHIFT_SCORE": {"percentile": 10},
                "FIRST_INPUT_DELAY_MS": {"percentile": 50}
            }
        },
        "lighthouseResult": {
            "categories": {
                "performance": {"score": 0.95}
            }
        }
    }
    
    with patch(
        "services.scraper_service._fetch_text",
        new_callable=AsyncMock,
        return_value=json.dumps(mock_data),
    ):
        result = await scraper_service.get_pagespeed_metrics("https://example.com")
        
        assert result["error"] is None
        assert result["lcp"] == 1200
        assert result["cls"] == 10
        assert result["fid"] == 50
        assert result["score"] == 0.95

@pytest.mark.asyncio
async def test_get_pagespeed_metrics_failure():
    with patch(
        "services.scraper_service._fetch_text",
        new_callable=AsyncMock,
        side_effect=ScraperRequestError("Website returned HTTP 500"),
    ):
        result = await scraper_service.get_pagespeed_metrics("https://example.com")
        
        assert result["error"] == "Website returned HTTP 500"
        assert result["score"] is None


@pytest.mark.asyncio
async def test_get_pagespeed_metrics_rejects_unexpected_payload():
    with patch(
        "services.scraper_service._fetch_text",
        new_callable=AsyncMock,
        return_value="[]",
    ):
        result = await scraper_service.get_pagespeed_metrics("https://example.com")

    assert result["error"] == "PageSpeed returned an unexpected payload"
    assert result["score"] is None


def test_jsonld_reader_facts_skip_breadcrumb_and_article_metadata():
    soup = BeautifulSoup(
        """
        <script type="application/ld+json">
        {
          "@type": "Article",
          "headline": "Repeated headline",
          "datePublished": "2026-07-11",
          "itemListElement": [{"position": 1, "name": "News"}],
          "offers": {"price": 19, "priceCurrency": "EUR"}
        }
        </script>
        """,
        "html.parser",
    )

    facts = _extract_jsonld_facts(soup)

    assert "headline" not in facts
    assert "itemListElement" not in facts
    assert "datePublished" not in facts
    assert "offers price: 19" in facts
