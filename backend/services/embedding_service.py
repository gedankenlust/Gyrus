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


class EmbeddingUnavailableError(Exception):
    """Raised when the embedding model cannot be reached or returns no vector."""


async def get_embedding(
    text: str,
    model: str = DEFAULT_MODEL,
    base_url: str = DEFAULT_BASE_URL,
) -> list[float]:
    """Return a vector for *text* using Ollama's /api/embeddings endpoint.

    Truncates the input to 8 000 characters before sending so we never hit
    the model's context limit (nomic-embed-text supports ~8 192 tokens).
    """
    if not text or not text.strip():
        raise EmbeddingUnavailableError("Empty text — cannot embed.")

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
