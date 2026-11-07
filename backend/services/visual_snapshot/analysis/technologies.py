"""Technology detection from rendered-page signals and loaded scripts."""

import re
from typing import Any, Iterable

from services.visual_snapshot.config import MAX_TECHNOLOGY_SCRIPT_BYTES


_TECHNOLOGY_RULES = (
    ("WordPress", "CMS", ("wp-content", "wp-includes", "wp-json")),
    ("WooCommerce", "E-Commerce", ("woocommerce", "wc-blocks")),
    ("Shopify", "E-Commerce", ("shopify", "myshopify", "cdn.shopify.com")),
    ("Webflow", "Website Builder", ("webflow.js", "webflow.io", "data-wf-page", "data-wf-site")),
    ("Framer", "Website Builder", ("framerusercontent", "framer.com/m/")),
    ("Wix", "Website Builder", ("wix.com", "wixstatic", "parastorage", "wix-code")),
    ("Squarespace", "Website Builder", ("static1.squarespace", "assets.squarespace")),
    ("STRATO", "Hosting / Builder", ("strato", "strato-editor", "websites-editor")),
    ("Drupal", "CMS", ("drupalsettings", "sites/default/files", "/core/misc/drupal")),
    ("TYPO3", "CMS", ("typo3", "typo3temp", "typo3conf")),
    ("Ghost", "CMS", ("ghost.io", "ghost.org", "/ghost/")),
    ("Next.js", "Framework", ("__next_data__", "/_next/")),
    ("Nuxt", "Framework", ("__nuxt__", "/_nuxt/")),
    ("Astro", "Framework", ("astro-island", "/_astro/")),
    ("Gatsby", "Framework", ("___gatsby", "/page-data/")),
    ("SvelteKit", "Framework", ("/_app/immutable/", "data-sveltekit")),
    ("Angular", "Framework", ("@angular/", "angular.min.js", "ng-version")),
    ("Vue", "Framework", ("vue.runtime", "vue.global", "vue.min.js", "data-v-app")),
    ("TanStack Start", "Framework", ("tanstack-start", "tsr-stream-barrier")),
    ("TanStack Router", "Router", ("tanstack-router", "data-route-announcer", "router-compat")),
    ("React", "UI Library", ("react-dom", "react.production", "__reactfiber", "__reactcontainer")),
    ("Vite", "Build Tool", ("vite-build-assets", "/@vite/", "vite/client")),
    ("Tailwind CSS", "CSS Framework", ("tailwind", "--tw-")),
    ("Bootstrap", "CSS Framework", ("bootstrap",)),
    ("Radix UI", "Component Library", ("data-radix", "radix-ui")),
    ("Lucide", "Icon Library", ("lucide", "createLucideIcon")),
    ("Motion", "Animation Library", ("/motion-", "motion/react", "framer-motion")),
    ("Plausible", "Analytics", ("plausible.js", "plausible.io")),
    ("Google Analytics 4", "Analytics", ("google-analytics-4", "googletagmanager.com/gtag")),
    ("Custom CSS", "Styling", ("custom-css",)),
    ("CSS Design Tokens", "Design System", ("css-design-tokens",)),
    ("Self-hosted Fonts", "Typography", ("self-hosted-fonts",)),
    ("Canvas 2D", "Graphics", ("canvas-2d",)),
    ("SSR + Hydration", "Rendering", ("ssr-hydration",)),
    ("PWA Manifest", "PWA", ("web-app-manifest",)),
    ("Apache", "Web Server", ("apache",)),
    ("Plesk", "Server Management", ("plesk", "plesklin")),
)


_SCRIPT_CONTENT_FINGERPRINTS = (
    ("TanStack Start", ("$tsr-stream-barrier", "tanstack-start", "createserverfn")),
    ("TanStack Router", ("data-route-announcer", "router-compat", "@tanstack/router")),
    ("Vite", ("__vite__mapdeps", "vite/modulepreload-polyfill")),
    ("Radix UI", ("data-radix-collection-item", "radix-ui", "radix-collection")),
    ("Lucide", ("createlucideicon", "lucide-react", "lucide-vue")),
    ("Motion", ("framer-motion", "motion/react", "motion-dom", "motionconfigcontext")),
    ("Plausible", ("/scripts/plausible.js", "plausible.io/js/")),
    ("Google Analytics 4", ("googletagmanager.com/gtag/js", "gtag('config'", "gtag(\"config\"")),
    ("Canvas 2D", ("getcontext('2d')", "getcontext(\"2d\")")),
)


def script_content_markers(content: bytes) -> list[str]:
    """Return known library fingerprints without retaining third-party code."""
    if not content or len(content) > MAX_TECHNOLOGY_SCRIPT_BYTES:
        return []

    lowered = content.decode("utf-8", errors="ignore").lower()
    return [
        name
        for name, needles in _SCRIPT_CONTENT_FINGERPRINTS
        if any(needle in lowered for needle in needles)
    ]


def script_technology_versions(content: bytes) -> dict[str, str]:
    """Extract versions only from explicit package metadata in loaded scripts."""
    if not content or len(content) > MAX_TECHNOLOGY_SCRIPT_BYTES:
        return {}

    text = content.decode("utf-8", errors="ignore")
    react_match = re.search(
        r"version\s*:\s*[`\"']([0-9]+(?:\.[0-9]+){1,3}(?:[-+][0-9A-Za-z.-]+)?)"
        r"[`\"']\s*,\s*rendererPackageName\s*:\s*[`\"']react-dom[`\"']",
        text,
        flags=re.IGNORECASE,
    )
    return {"React": react_match.group(1)} if react_match else {}


def declared_script_size(headers: dict[str, str]) -> int | None:
    """Return a trustworthy, bounded body size for optional script inspection.

    Playwright exposes a completed response body as one bytes object, not a
    stream. Refusing bodies without a valid Content-Length avoids copying an
    attacker-controlled chunked response into the Python process.
    """
    raw = headers.get("content-length", "").strip()
    if not raw:
        return None
    try:
        size = int(raw)
    except ValueError:
        return None
    if size <= 0 or size > MAX_TECHNOLOGY_SCRIPT_BYTES:
        return None
    return size


def is_javascript_response(url: str, content_type: str) -> bool:
    return (
        "javascript" in content_type.lower()
        or url.lower().split("?", 1)[0].endswith((".js", ".mjs"))
    )


def is_primary_script_bundle(url: str) -> bool:
    """Keep the entry bundle eligible even when preload chunks fill the probe cap."""
    path = url.lower().split("?", 1)[0]
    return bool(
        re.search(
            r"/(?:index|main|app)-(?=[a-z0-9_-]{6,}\.m?js$)(?=[a-z0-9_-]*\d)"
            r"[a-z0-9_-]+\.m?js$",
            path,
        )
    )


def enrich_technology_signals(
    signals: dict[str, Any] | None,
    *,
    script_markers: Iterable[str],
    technology_versions: dict[str, str],
    response_headers: list[str],
) -> dict[str, Any] | None:
    """Add what the browser observed outside the page to the page's own signals.

    ``None`` stays ``None``: a page that produced no signals must not be
    classified from network evidence alone.
    """
    if signals is None:
        return None
    signals["script_content_markers"] = sorted(script_markers)
    signals["technology_versions"] = technology_versions
    signals["response_headers"] = response_headers
    return signals


def detect_technologies(signals: dict[str, Any] | None) -> list[dict[str, Any]]:
    """Classify rendered-page signals without guessing beyond the evidence."""
    if not signals:
        return []

    generator = str(signals.get("generator") or "").strip()
    marker_names = {
        str(name).lower()
        for name in signals.get("runtime_markers") or []
        if str(name).strip()
    }
    script_content_marker_names = {
        str(name).lower()
        for name in signals.get("script_content_markers") or []
        if str(name).strip()
    }
    technology_versions = {
        str(name).lower(): str(version).strip()
        for name, version in (signals.get("technology_versions") or {}).items()
        if str(name).strip() and str(version).strip()
    }
    sources = [
        ("Generator", generator),
        *[("Script", str(value)) for value in signals.get("script_urls") or []],
        *[("Stylesheet", str(value)) for value in signals.get("stylesheet_urls") or []],
        *[("Markup", str(value)) for value in signals.get("markup_hints") or []],
        *[("Header", str(value)) for value in signals.get("response_headers") or []],
    ]

    technologies: list[dict[str, Any]] = []
    generator_was_classified = False
    for name, category, needles in _TECHNOLOGY_RULES:
        normalized_needles = tuple(needle.lower() for needle in needles)
        evidence: list[str] = []
        marker_match = name.lower() in marker_names
        content_marker_match = name.lower() in script_content_marker_names
        if marker_match:
            evidence.append(f"Runtime marker: {name}")
        if content_marker_match:
            evidence.append(f"Loaded JavaScript fingerprint: {name}")

        for source, value in sources:
            if not value:
                continue
            lowered = value.lower()
            matches = (
                name.lower() in lowered
                if source == "Generator"
                else any(needle in lowered for needle in normalized_needles)
            )
            if matches:
                evidence.append(f"{source}: {value[:180]}")
                if source == "Generator":
                    generator_was_classified = True
            if len(evidence) >= 3:
                break

        if evidence:
            technology = {
                "name": name,
                "category": category,
                "confidence": "high" if marker_match or content_marker_match or any(
                    item.startswith(("Generator:", "Header:")) for item in evidence
                ) else "medium",
                "evidence": evidence,
            }
            version = technology_versions.get(name.lower())
            if not version and generator:
                generator_version = re.search(
                    rf"\b{re.escape(name)}\s+v?([0-9]+(?:\.[0-9]+){{1,3}}(?:[-+][0-9A-Za-z.-]+)?)",
                    generator,
                    flags=re.IGNORECASE,
                )
                if generator_version:
                    version = generator_version.group(1)
            if version:
                technology["version"] = version
            technologies.append(technology)

    if generator and not generator_was_classified:
        technologies.append(
            {
                "name": generator[:80],
                "category": "Site Generator",
                "confidence": "high",
                "evidence": [f"Generator: {generator[:180]}"],
            }
        )

    detected_names = {technology["name"] for technology in technologies}
    architecture_categories = {
        "CMS",
        "Framework",
        "Site Generator",
        "UI Library",
        "Website Builder",
    }
    has_application_stack = bool(generator) or any(
        technology["category"] in architecture_categories
        for technology in technologies
    )
    generic_signals = signals.get("generic_signals") or {}
    same_origin_scripts = int(generic_signals.get("same_origin_script_count") or 0)
    module_scripts = int(generic_signals.get("module_script_count") or 0)
    semantic_elements = int(generic_signals.get("semantic_content_element_count") or 0)

    if same_origin_scripts > 0 and not has_application_stack:
        technologies.append(
            {
                "name": "Vanilla JavaScript",
                "category": "JavaScript",
                "confidence": "medium",
                "evidence": [
                    f"Inference: {same_origin_scripts} first-party script(s) and no detected JavaScript framework."
                ],
            }
        )

    if (
        semantic_elements >= 3
        and module_scripts == 0
        and not has_application_stack
        and "SSR + Hydration" not in detected_names
    ):
        technologies.append(
            {
                "name": "Static HTML",
                "category": "Rendering",
                "confidence": "medium",
                "evidence": [
                    "Inference: semantic document content with no detected CMS, site generator, hydration, or application framework."
                ],
            }
        )

    return technologies
