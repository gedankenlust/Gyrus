"""User-facing response texts that are chosen by the app's `language` field.

The app sends its UI language ("en" / "de") with requests that start work
whose result is shown verbatim (HTTP error details, job status messages).
Keeping every such text here means a wording change or a new language does
not require hunting through routers and job services. LLM prompts are not
collected here: they are instructions to a model, not text shown to people.
"""

MESSAGES: dict[str, dict[str, str]] = {
    # POST /api/bookmarks/auto-tag-batch with too small a selection.
    "taxonomy_minimum": {
        "en": "Select at least {minimum} bookmarks to build a tag system.",
        "de": "Wähle mindestens {minimum} Lesezeichen, um ein Tag-System zu erstellen.",
    },
    # Folder organization job status messages.
    "folders_empty_library": {
        "en": "There are no bookmarks to sort.",
        "de": "Es gibt keine Lesezeichen zum Sortieren.",
    },
    "folders_waiting_for_model": {
        "en": "Waiting for Ollama. The first answer can take a few minutes while the model loads.",
        "de": "Warte auf Ollama. Die erste Antwort kann ein paar Minuten dauern, während das Modell lädt.",
    },
    "folders_model_timeout": {
        "en": "The local model did not answer in time. Nothing was moved. Start sorting again; the model stays loaded now.",
        "de": "Ollama hat zu lange gebraucht. Es wurde nichts verschoben. Starte die Sortierung noch einmal, das Modell bleibt jetzt geladen.",
    },
    "folders_stopped": {
        "en": "Stopped before anything was moved.",
        "de": "Gestoppt, bevor etwas verschoben wurde.",
    },
    "folders_no_structure": {
        "en": "The local model did not return a folder structure. Nothing was moved.",
        "de": "Die lokale KI hat keine Ordnerstruktur geliefert. Es wurde nichts verschoben.",
    },
    "folders_nothing_assigned": {
        "en": "The local model did not assign any bookmarks. Nothing was moved.",
        "de": "Die lokale KI hat keine Lesezeichen zugeordnet. Es wurde nichts verschoben.",
    },
    "folders_moving": {
        "en": "Moving bookmarks into the new folders.",
        "de": "Lesezeichen werden in die neuen Ordner verschoben.",
    },
    # Moves commit in chunks, so this must not promise that nothing changed.
    "folders_move_failed": {
        "en": "Moving the bookmarks into the new folders failed.",
        "de": "Das Verschieben der Lesezeichen in die neuen Ordner ist fehlgeschlagen.",
    },
    "folders_done": {
        "en": "Moved {moved} bookmarks into {created} folders. {stayed} stayed. Empty old folders are left in place.",
        "de": "{moved} Lesezeichen wurden in {created} Ordner verschoben. {stayed} bleiben liegen. Leere alte Ordner bleiben stehen.",
    },
}


def is_german(language: str | None) -> bool:
    """Any German locale ("de", "de-DE", "DE") selects German."""
    return (language or "").lower().startswith("de")


def localized(key: str, german: bool, **fields) -> str:
    """The message for `key`, in German when `german`, else English.

    Callers decide `german` themselves because the endpoints historically
    differ: job messages accept any German locale (`is_german`), while the
    auto-tag-batch error only switches for exactly "de".
    """
    text = MESSAGES[key]["de" if german else "en"]
    return text.format(**fields) if fields else text
