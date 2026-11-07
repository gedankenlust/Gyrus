"""Tag names: normalization, canonical comparison and the broad vocabulary."""
from __future__ import annotations

import re

MAX_NAME_CHARS = 40
MAX_WORDS = 4
MAX_TAGS_PER_BOOKMARK = 3

_ALIASES = {
    "development tool": "developer tools",
    "development tools": "developer tools",
    "developer tool": "developer tools",
    "software developer tool": "developer tools",
    "software developer tools": "developer tools",
    "ai assisted software development": "ai-assisted development",
    "ai assisted development": "ai-assisted development",
    "artificial intelligence": "ai",
    "coworking space": "coworking",
    "coworking spaces": "coworking",
    "real estate listings": "real estate",
    "real estate listing": "real estate",
    "property listings": "real estate",
    "data visualisation": "data visualization",
    "web design": "webdesign",
    "finanzen software": "finanzsoftware",
    "finanz technologie": "finanztechnologie",
    "system programmierung": "systemprogrammierung",
    "video bearbeitung": "videobearbeitung",
    "coworking räume": "coworking",
    "temporär bau": "temporärer bau",
    "gebrauchtfahrzeuge": "gebrauchte fahrzeuge",
}
_PLURAL_EXCEPTIONS = {"business", "news", "sports", "css", "physics"}

# A stable vocabulary gives small local models a much easier task than asking
# them to invent and consistently reuse category names across a large library.
# The terms are deliberately broad: this feature organizes a collection; it is
# not meant to create a unique keyword for every page.
_BROAD_TAGS = {
    "de": {
        "ki": "Künstliche Intelligenz, Sprachmodelle, Machine Learning, KI-Agenten",
        "softwareentwicklung": "Programmierung, Entwicklerwerkzeuge, APIs, Quellcode",
        "webentwicklung": "Webanwendungen, Browsertechnik, Frontend, Backend, Webstandards",
        "webdesign": "Websites gestalten, UI, UX, Layout, Typografie",
        "design": "Grafikdesign, Designsysteme, visuelle Gestaltung, kreative Werkzeuge",
        "open source": "freie Software, GitHub-Projekte, offene Quelltexte",
        "produktivität": "Arbeitsorganisation, Notizen, Workflows, persönliche Werkzeuge",
        "daten": "Datenanalyse, Datenbanken, Visualisierung, CSV, Statistik",
        "cloud computing": "Cloud, Server, Hosting, virtuelle Maschinen, Infrastruktur",
        "automatisierung": "Automatisierung, Skripte, Integrationen, Workflows",
        "cybersicherheit": "IT-Sicherheit, Verschlüsselung, Schwachstellen, Schutz",
        "datenschutz": "Privatsphäre, Tracking, personenbezogene Daten, Datenschutzrecht",
        "finanzen": "Geld, Banking, Investment, Börse, Wirtschaft",
        "kryptowährungen": "Blockchain, Bitcoin, Krypto-Handel, digitale Vermögenswerte",
        "immobilien": "Häuser, Wohnungen, Grundstücke, Immobilienangebote",
        "fahrzeuge": "Autos, Transporter, Motorräder, Fahrzeugmarkt",
        "camping": "Wohnmobile, Camper, Campingplätze, Vanlife",
        "reisen": "Reiseziele, Urlaub, Unterkünfte, Tourismus",
        "wohnen": "Einrichtung, Haushalt, Wohnen, Haushaltsgeräte",
        "bauwesen": "Bauen, Baustoffe, Architektur, Sanierung",
        "handwerk": "Reparatur, Werkstatt, Selbermachen, handwerkliche Arbeit",
        "gesundheit": "Medizin, Fitness, Ernährung, psychische Gesundheit",
        "wissenschaft": "Forschung, Naturwissenschaften, wissenschaftliche Erkenntnisse",
        "bildung": "Lernen, Bücher, Kurse, Wissen, Lernmethoden",
        "karriere": "Jobs, Bewerbung, Beruf, Arbeitsplatz",
        "unternehmen": "Firmen, Geschäftsmodelle, Dienstleistungen, Unternehmertum",
        "marketing": "Werbung, Marken, SEO, Vertrieb, Kommunikation",
        "e-commerce": "Onlineshops, Produkte, Preisvergleich, digitaler Handel",
        "elektronik": "Elektronische Geräte, Hardware, Schaltungen, Messtechnik",
        "amateurfunk": "Funktechnik, SDR, Empfänger, Antennen, Amateurfunk",
        "audio": "Audiotechnik, Ton, Aufnahme, Podcasts",
        "video": "Videoproduktion, Videoschnitt, Bewegtbild, Streaming",
        "fotografie": "Kameras, Bilder, Fotobearbeitung, Fotografie",
        "musik": "Musikproduktion, Instrumente, Künstler, Musik",
        "spiele": "Computerspiele, Brettspiele, Gaming",
        "sport": "Sportarten, Training, Wettkämpfe, Vereine",
        "nachrichten": "Aktuelle Meldungen, Presse, Journalismus",
        "gesellschaft": "Politik, Kultur, gesellschaftliche Themen",
        "geschichte": "Historische Ereignisse, Personen, Zeitgeschichte",
        "natur": "Tiere, Pflanzen, Umwelt, Garten, Landschaft",
        "essen": "Kochen, Rezepte, Lebensmittel, Gastronomie",
        "recht": "Gesetze, Verträge, Gerichte, rechtliche Beratung",
    },
    "en": {
        "ai": "artificial intelligence, language models, machine learning, AI agents",
        "software development": "programming, developer tools, APIs, source code",
        "web development": "web applications, browsers, frontend, backend, web standards",
        "web design": "website design, UI, UX, layout, typography",
        "design": "graphic design, design systems, visual design, creative tools",
        "open source": "free software, GitHub projects, open source code",
        "productivity": "work organization, notes, workflows, personal tools",
        "data": "data analysis, databases, visualization, CSV, statistics",
        "cloud computing": "cloud, servers, hosting, virtual machines, infrastructure",
        "automation": "automation, scripts, integrations, workflows",
        "cybersecurity": "IT security, encryption, vulnerabilities, protection",
        "privacy": "privacy, tracking, personal data, privacy law",
        "finance": "money, banking, investing, stock market, economics",
        "cryptocurrency": "blockchain, Bitcoin, crypto trading, digital assets",
        "real estate": "houses, apartments, property, real estate listings",
        "vehicles": "cars, vans, motorcycles, vehicle market",
        "camping": "motorhomes, campers, campsites, vanlife",
        "travel": "destinations, vacations, accommodation, tourism",
        "home": "interior, household, living, home appliances",
        "construction": "building, materials, architecture, renovation",
        "crafts": "repair, workshop, DIY, practical work",
        "health": "medicine, fitness, nutrition, mental health",
        "science": "research, natural sciences, scientific findings",
        "education": "learning, books, courses, knowledge, study methods",
        "career": "jobs, applications, profession, workplace",
        "business": "companies, business models, services, entrepreneurship",
        "marketing": "advertising, brands, SEO, sales, communication",
        "e-commerce": "online shops, products, price comparison, digital commerce",
        "electronics": "electronic devices, hardware, circuits, measurement",
        "amateur radio": "radio technology, SDR, receivers, antennas, ham radio",
        "audio": "audio technology, sound, recording, podcasts",
        "video": "video production, editing, motion, streaming",
        "photography": "cameras, images, photo editing, photography",
        "music": "music production, instruments, artists, music",
        "games": "video games, board games, gaming",
        "sports": "sports, training, competitions, clubs",
        "news": "current events, press, journalism",
        "society": "politics, culture, social issues",
        "history": "historical events, people, contemporary history",
        "nature": "animals, plants, environment, gardening, landscapes",
        "food": "cooking, recipes, groceries, restaurants",
        "law": "laws, contracts, courts, legal advice",
    },
}

_GENERIC_LABELS = {
    "apps", "app",
    "website", "websites", "article", "artikel", "tools", "tool",
    "general links", "allgemeine links", "miscellaneous", "sonstiges",
    "web tools",
}


def flat(value: str | None, limit: int) -> str:
    """Collapse whitespace and cut to ``limit`` characters."""
    return re.sub(r"\s+", " ", value or "").strip()[:limit]


def normalize_tag_name(value: str) -> str | None:
    name = value.casefold().replace("_", " ")
    name = re.sub(r"\s*-\s*", "-", name)
    name = re.sub(r"[^\wäöüß+#. -]", "", name, flags=re.UNICODE)
    name = re.sub(r"\s+", " ", name).strip()
    name = re.sub(r"^-+|-+$", "", name).strip()
    if not name or len(name) > MAX_NAME_CHARS or len(name.split()) > MAX_WORDS:
        return None
    return _ALIASES.get(name, name)


def canonical_key(name: str) -> str:
    """Comparison key that treats spelling variants and plurals as one tag."""
    key = re.sub(r"[-_.]+", " ", name.casefold())
    key = re.sub(r"\s+", " ", key).strip()
    key = _ALIASES.get(key, key)
    words = key.split()
    if words:
        last = words[-1]
        if last not in _PLURAL_EXCEPTIONS:
            if last.endswith("ies") and len(last) > 4:
                words[-1] = last[:-3] + "y"
            elif last.endswith("s") and not last.endswith("ss") and len(last) > 3:
                words[-1] = last[:-1]
    return " ".join(words)


def canonical_tag_key(name: str) -> str:
    """Public canonical comparison used by the single-bookmark tagger too."""
    return canonical_key(name)


def is_reusable_label(name: str, language: str | None) -> bool:
    lowered = name.casefold()
    if lowered in _GENERIC_LABELS:
        return False
    return not re.search(r"(?:\s+und\s+|\s+and\s+|\s*&\s*|\s*/\s*|,)", lowered)


def classification_catalog(language: str | None, existing_tags: list[str]) -> dict[str, str]:
    """Label -> description for every tag the model may assign."""
    language_key = "de" if language == "de" else "en"
    catalog = dict(_BROAD_TAGS[language_key])
    # User-created tags are part of the vocabulary too, but malformed legacy AI
    # labels must not leak back into a fresh run.
    for raw_name in existing_tags:
        name = normalize_tag_name(raw_name)
        if name and is_reusable_label(name, language) and name not in catalog:
            catalog[name] = name
    return catalog
