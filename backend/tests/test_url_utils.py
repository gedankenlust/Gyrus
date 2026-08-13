import pytest
from services.url_utils import normalize_url

def test_null_or_empty():
    assert normalize_url(None) == ""
    assert normalize_url("") == ""

def test_whitespace_stripping():
    assert normalize_url("  https://example.com  ") == "https://example.com"
    assert normalize_url("\t\thttps://example.com\n") == "https://example.com"

def test_bare_domains():
    assert normalize_url("example.com") == "example.com"
    assert normalize_url("localhost") == "localhost"

def test_lowercasing():
    assert normalize_url("HTTP://EXAMPLE.COM/Path") == "http://example.com/Path"
    assert normalize_url("Https://www.EXAMPLE.com") == "https://www.example.com"

def test_default_port_dropping():
    assert normalize_url("http://example.com:80/path") == "http://example.com/path"
    assert normalize_url("https://example.com:443/path") == "https://example.com/path"

def test_retention_of_non_default_ports():
    assert normalize_url("http://example.com:8080/path") == "http://example.com:8080/path"
    assert normalize_url("https://example.com:8443/path") == "https://example.com:8443/path"

def test_dropping_trailing_slashes():
    assert normalize_url("https://example.com/") == "https://example.com"
    assert normalize_url("https://example.com/path/") == "https://example.com/path"
    assert normalize_url("https://example.com///") == "https://example.com"

def test_tracking_parameter_removal():
    # Removal of common tracking parameters
    assert normalize_url("https://example.com/?utm_source=twitter&utm_medium=social") == "https://example.com"
    assert normalize_url("https://example.com/path?fbclid=12345") == "https://example.com/path"
    assert normalize_url("https://example.com/?_ga=12.34&gclid=test") == "https://example.com"
    # Case insensitivity in tracking parameter removal
    assert normalize_url("https://example.com/?UTM_SOURCE=twitter&FbClId=123") == "https://example.com"

def test_retention_of_functional_parameters_and_fragments():
    # Retention of non-tracking parameters
    assert normalize_url("https://youtube.com/watch?v=dQw4w9WgXcQ") == "https://youtube.com/watch?v=dQw4w9WgXcQ"
    # Mixed tracking and non-tracking parameters
    assert normalize_url("https://youtube.com/watch?utm_source=twitter&v=dQw4w9WgXcQ") == "https://youtube.com/watch?v=dQw4w9WgXcQ"
    # Fragments
    assert normalize_url("https://example.com/path#section-1") == "https://example.com/path#section-1"
    # Parameters and fragments
    assert normalize_url("https://example.com/path?page=1#top") == "https://example.com/path?page=1#top"
    assert normalize_url("https://example.com/path?utm_medium=social&page=1#top") == "https://example.com/path?page=1#top"

def test_retention_of_blank_query_parameter_values():
    assert normalize_url("https://example.com/?page=") == "https://example.com?page="
    assert normalize_url("https://example.com/?page=&utm_source=twitter") == "https://example.com?page="

def test_invalid_url_fallback():
    # Invalid IPv6 URL causes a ValueError in urlsplit
    assert normalize_url("http://[::1") == "http://[::1"

def test_multiple_identical_query_parameters():
    assert normalize_url("http://example.com/?q=1&q=2") == "http://example.com?q=1&q=2"

def test_other_url_schemes():
    assert normalize_url("mailto:user@example.com") == "mailto:user@example.com"
    assert normalize_url("file:///tmp/test.txt") == "file:///tmp/test.txt"
    assert normalize_url("javascript:alert(1)") == "javascript:alert(1)"

def test_credentials_in_url():
    assert normalize_url("http://user:pass@example.com/") == "http://user:pass@example.com"
    assert normalize_url("http://User:Pass@Example.com/") == "http://user:pass@example.com"

def test_empty_query_or_fragment():
    assert normalize_url("http://example.com/?") == "http://example.com"
    assert normalize_url("http://example.com/#") == "http://example.com"

def test_invalid_port_numbers():
    assert normalize_url("http://example.com:80a/path") == "http://example.com:80a/path"

def test_scheme_less_urls():
    assert normalize_url("//example.com/path") == "//example.com/path"
