"""Local embedding generation via Ollama.

Converts text → a 768-dimensional float vector using nomic-embed-text (or any
other model the user has installed).  Vectors are consumed by the semantic
search pipeline: stored in the bookmarks_vec virtual table and queried at
search time via sqlite-vec's KNN operator.

Designed to be optional: if Ollama is unreachable every call raises
EmbeddingUnavailableError so callers can degrade gracefully to keyword search.
"""
import logging
from typing import Optional

import httpx

logger = logging.getLogger(__name__)

DEFAULT_MODEL = "nomic-embed-text"
DEFAULT_BASE_URL = "http://localhost:11434"
TIMEOUT = 30.0

# Active embedding config, pushed from the app via /api/brain/config. Embeddings
# are generated server-side (background indexing + search) with no per-request
# model, so the chosen model/URL live here as module state. Different models
# produce different vector sizes (nomic = 768, bge-m3 = 1024), which is why a
# model change requires a full reindex (see vector_store.reset_table).
_active_model = DEFAULT_MODEL
_active_base_url = DEFAULT_BASE_URL


def set_active_model(model: Optional[str]) -> None:
    global _active_model
    if model and model.strip():
        _active_model = model.strip()


def set_active_base_url(url: Optional[str]) -> None:
    global _active_base_url
    if url and url.strip():
        _active_base_url = url.strip()


def current_model() -> str:
    return _active_model


class EmbeddingUnavailableError(Exception):
    """Raised when the embedding model cannot be reached or returns no vector."""


async def get_embedding(
    text: str,
    model: Optional[str] = None,
    base_url: Optional[str] = None,
) -> list[float]:
    """Return a vector for *text* using Ollama's /api/embeddings endpoint.

    Defaults to the active configured model/URL (set via /api/brain/config).
    Truncates the input to 8 000 characters before sending so we never hit
    the model's context limit (nomic-embed-text supports ~8 192 tokens).
    """
    if not text or not text.strip():
        raise EmbeddingUnavailableError("Empty text — cannot embed.")

    model = model or _active_model
    base_url = base_url or _active_base_url

    payload = {"model": model, "prompt": text[:8_000]}
    try:
        async with httpx.AsyncClient(timeout=TIMEOUT) as client:
            resp = await client.post(f"{base_url}/api/embeddings", json=payload)
            resp.raise_for_status()
            data = resp.json()
    except httpx.ConnectError:
        raise EmbeddingUnavailableError(
            f"Couldn't reach Ollama at {base_url}. "
            "Make sure it's running to use semantic search."
        )
    except Exception as e:
        raise EmbeddingUnavailableError(f"Embedding request failed: {e}")

    vec = data.get("embedding")
    if not vec:
        raise EmbeddingUnavailableError(
            f"Ollama returned no embedding for model '{model}'. "
            "Is the model installed? (ollama pull nomic-embed-text)"
        )
    return vec


async def get_embeddings(
    texts: list[str],
    model: Optional[str] = None,
    base_url: Optional[str] = None,
) -> list[list[float]]:
    """Embed a collection in one Ollama request for taxonomy clustering."""
    cleaned = [text[:4_000] for text in texts if text and text.strip()]
    if len(cleaned) != len(texts) or not cleaned:
        raise EmbeddingUnavailableError("Every taxonomy item needs text to embed.")

    model = model or _active_model
    base_url = base_url or _active_base_url
    # Taxonomy generation immediately switches to a language model. Ask Ollama
    # to release the embedding model after this response so both do not occupy
    # memory at once.
    payload = {
        "model": model,
        "input": cleaned,
        "truncate": True,
        "keep_alive": 0,
    }
    try:
        async with httpx.AsyncClient(timeout=180.0) as client:
            resp = await client.post(f"{base_url}/api/embed", json=payload)
            resp.raise_for_status()
            data = resp.json()
    except httpx.ConnectError:
        raise EmbeddingUnavailableError(
            f"Couldn't reach Ollama at {base_url}. Make sure it's running."
        )
    except httpx.TimeoutException:
        raise EmbeddingUnavailableError(
            "Ollama took too long to analyze the selected bookmarks."
        )
    except Exception as exc:
        raise EmbeddingUnavailableError(f"Embedding request failed: {exc}")

    vectors = data.get("embeddings")
    if not isinstance(vectors, list) or len(vectors) != len(texts) or not all(vectors):
        raise EmbeddingUnavailableError(
            f"Ollama returned incomplete embeddings for model '{model}'."
        )
    return vectors
