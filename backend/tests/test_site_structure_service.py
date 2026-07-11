import pytest

from services.site_structure_service import FetchResult, SiteStructureService


@pytest.mark.asyncio
async def test_site_structure_crawl_counts_same_origin_pages(monkeypatch, tmp_path):
    service = SiteStructureService()
    service.cache_dir = tmp_path
    service.max_pages = 10

    pages = {
        "https://example.com/sitemap.xml": FetchResult(
            "https://example.com/sitemap.xml",
            "application/xml",
            """
            <urlset>
              <url><loc>https://example.com/</loc></url>
              <url><loc>https://example.com/about</loc></url>
            </urlset>
            """,
        ),
        "https://example.com/": FetchResult(
            "https://example.com/",
            "text/html",
            """
            <html><head><title>Home</title><meta name="description" content="Start"></head>
            <body><h1>Welcome</h1><a href="/about">About</a><a href="/contact">Contact</a>
            <a href="/image.jpg">Asset</a><a href="https://other.test/page">External</a></body></html>
            """,
        ),
        "https://example.com/about": FetchResult(
            "https://example.com/about",
            "text/html",
            "<html><head><title>About</title></head><body><h1>About us</h1></body></html>",
        ),
        "https://example.com/contact": FetchResult(
            "https://example.com/contact",
            "text/html",
            "<html><head><title>Contact</title></head><body><h1>Contact</h1></body></html>",
        ),
    }

    async def fake_fetch(_client, url, _accept):
        return pages.get(url)

    monkeypatch.setattr(service, "_fetch_text", fake_fetch)

    data = await service.crawl("https://example.com/")
    context = service._format_context(data)

    assert len(data["pages"]) == 3
    assert "Exact discovered/listed page count to report: 3" in context
    assert "Count source: sitemap plus internal crawl" in context
    assert "Same-origin page URLs listed in sitemap(s): 2" in context
    assert "Never estimate" in context
    assert "- / — Home" in context
    assert "- /about — About" in context
    assert "- /contact — Contact" in context
    assert "image.jpg" not in context
    assert "other.test" not in context


def test_site_structure_prompt_detection():
    service = SiteStructureService()

    assert service.should_include_for_prompt("Wie viele Seiten hat die Webseite?")
    assert service.should_include_for_prompt("Wieviele Seiten gibt es?")
    assert service.should_include_for_prompt("Liste alle Unterseiten auf")
    assert service.should_include_for_prompt("how many pages are on this site?")
    assert not service.should_include_for_prompt("Fasse diese Seite zusammen")


@pytest.mark.asyncio
async def test_site_structure_reads_sitemap_indexes(monkeypatch, tmp_path):
    service = SiteStructureService()
    service.cache_dir = tmp_path
    service.max_pages = 10

    pages = {
        "https://example.com/sitemap.xml": FetchResult(
            "https://example.com/sitemap.xml",
            "application/xml",
            """
            <sitemapindex>
              <sitemap><loc>https://example.com/page-sitemap.xml</loc></sitemap>
            </sitemapindex>
            """,
        ),
        "https://example.com/sitemap_index.xml": None,
        "https://example.com/wp-sitemap.xml": None,
        "https://example.com/page-sitemap.xml": FetchResult(
            "https://example.com/page-sitemap.xml",
            "application/xml",
            """
            <urlset>
              <url><loc>https://example.com/</loc></url>
              <url><loc>https://example.com/services</loc></url>
              <url><loc>https://example.com/sitemap-helper.xml</loc></url>
            </urlset>
            """,
        ),
        "https://example.com/": FetchResult(
            "https://example.com/",
            "text/html",
            "<html><head><title>Home</title></head><body><h1>Home</h1></body></html>",
        ),
        "https://example.com/services": FetchResult(
            "https://example.com/services",
            "text/html",
            "<html><head><title>Services</title></head><body><h1>Services</h1></body></html>",
        ),
    }

    async def fake_fetch(_client, url, _accept):
        return pages.get(url)

    monkeypatch.setattr(service, "_fetch_text", fake_fetch)

    data = await service.crawl("https://example.com/")
    context = service._format_context(data)

    assert data["sitemap_pages"] == 2
    assert len(data["sitemap_sources"]) == 2
    assert "Exact discovered/listed page count to report: 2" in context
    assert "Count source: sitemap" in context
