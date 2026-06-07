"""URL normalization for duplicate detection.

Two URLs that point at the same page should be treated as one bookmark, even
when they differ only in tracking parameters, a trailing slash, scheme case, or
a default port. We normalize on save so the existing UNIQUE(url) constraint
catches these near-duplicates instead of letting them pile up silently.

We deliberately keep *functional* query params (e.g. youtube `?v=...`) — only
known tracking keys are stripped.
"""
from urllib.parse import urlsplit, urlunsplit, parse_qsl, urlencode

# Common analytics / click-tracking params that never change the destination.
_TRACKING_PARAMS = {
    "utm_source", "utm_medium", "utm_campaign", "utm_term", "utm_content",
    "utm_id", "utm_name", "utm_reader", "utm_social", "utm_brand",
    "fbclid", "gclid", "gclsrc", "dclid", "msclkid", "yclid",
    "mc_cid", "mc_eid", "igshid", "ref_src", "ref_url", "_ga",
}


def normalize_url(url: str) -> str:
    """Return a canonical form of *url* for comparison and storage.

    Falls back to the trimmed input if the URL can't be parsed, so a weird
    value is never lost.
    """
    raw = (url or "").strip()
    if not raw:
        return raw
    try:
        parts = urlsplit(raw)
    except ValueError:
        return raw

    # A bare "example.com" parses with empty scheme/netloc — leave such inputs
    # untouched rather than mangling them.
    if not parts.scheme or not parts.netloc:
        return raw

    scheme = parts.scheme.lower()
    host = parts.netloc.lower()
    if scheme == "http" and host.endswith(":80"):
        host = host[:-3]
    elif scheme == "https" and host.endswith(":443"):
        host = host[:-4]

    # Drop trailing slashes, including the bare root "/", so example.com,
    # example.com/ and example.com/// all collapse to the same canonical URL.
    path = parts.path.rstrip("/")

    kept = [(k, v) for k, v in parse_qsl(parts.query, keep_blank_values=True)
            if k.lower() not in _TRACKING_PARAMS]
    query = urlencode(kept)

    return urlunsplit((scheme, host, path, query, parts.fragment))
