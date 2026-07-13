import pytest
import httpx
from bs4 import BeautifulSoup
from unittest.mock import AsyncMock, patch, MagicMock
from services.scraper_service import _extract_jsonld_facts, scraper_service

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
    
    with patch("httpx.AsyncClient.get", new_callable=AsyncMock) as mock_get:
        mock_response = MagicMock()
        mock_response.status_code = 200
        mock_response.text = html_content
        mock_response.raise_for_status = lambda: None
        mock_get.return_value = mock_response
        
        result = await scraper_service.extract_content("https://example.com")
        
        assert result["error"] is None
        # readability-lxml might extract "Test Page" or "Main Title" depending on implementation
        assert result["title"] in ["Test Page", "Main Title"]
        assert "readability should find" in result["content"]
        assert "h1: Main Title" in result["structural_summary"]
        assert "h2: Subheading" in result["structural_summary"]

@pytest.mark.asyncio
async def test_extract_content_failure():
    with patch("httpx.AsyncClient.get", new_callable=AsyncMock) as mock_get:
        mock_get.side_effect = httpx.HTTPStatusError("404 Not Found", request=None, response=MagicMock(status_code=404))
        
        result = await scraper_service.extract_content("https://example.com/404")
        
        assert result["error"] is not None
        assert result["content"] == ""

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
    
    with patch("httpx.AsyncClient.get", new_callable=AsyncMock) as mock_get:
        mock_response = MagicMock()
        mock_response.status_code = 200
        mock_response.json.return_value = mock_data
        mock_get.return_value = mock_response
        
        result = await scraper_service.get_pagespeed_metrics("https://example.com")
        
        assert result["error"] is None
        assert result["lcp"] == 1200
        assert result["cls"] == 10
        assert result["fid"] == 50
        assert result["score"] == 0.95

@pytest.mark.asyncio
async def test_get_pagespeed_metrics_failure():
    with patch("httpx.AsyncClient.get", new_callable=AsyncMock) as mock_get:
        mock_response = MagicMock()
        mock_response.status_code = 500
        mock_get.return_value = mock_response
        
        result = await scraper_service.get_pagespeed_metrics("https://example.com")
        
        assert result["error"] == "API returned 500"
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
