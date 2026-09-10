"""Local embedding generation via Ollama.

Converts text → a 768-dimensional float vector using nomic-embed-text (or any
other model the user has installed).  Vectors are consumed by the semantic
search pipeline: stored in the bookmarks_vec virtual table and queried at
search time via sqlite-vec's KNN operator.

Designed to be optional: if Ollama is unreachable every call raises
EmbeddingUnavailableError so callers can degrade gracefully to keyword search.
"""
import logging
import math
import time
from typing import Optional, Callable, Awaitable

import httpx

from services import ai_policy

logger = logging.getLogger(__name__)

DEFAULT_MODEL = "nomic-embed-text"
DEFAULT_BASE_URL = "http://localhost:11434"
TIMEOUT = 30.0
EMBEDDING_BATCH_SIZE = 32

# Active embedding config, pushed from the app via /api/brain/config. Embeddings
# are generated server-side (background indexing + search) with no per-request
# model, so the chosen model/URL live here as module state. Different models
# produce different vector sizes (nomic = 768, bge-m3 = 1024), which is why a
# model change requires a full reindex (see vector_store.reset_table).
_active_model = DEFAULT_MODEL
_active_base_url = DEFAULT_BASE_URL


def set_active_model(model: Optional[str]) -> None:
    global _active_model
    if model and model.strip() and model.strip() != _active_model:
        ai_policy.invalidate_requests()
        _active_model = model.strip()


def set_active_base_url(url: Optional[str]) -> None:
    global _active_base_url
    if url and url.strip() and url.strip().rstrip("/") != _active_base_url:
        ai_policy.invalidate_requests()
        _active_base_url = url.strip().rstrip("/")


def current_model() -> str:
    return _active_model


def current_base_url() -> str:
    return _active_base_url


class EmbeddingUnavailableError(Exception):
    """Raised when the embedding model cannot be reached or returns no vector."""

    def __init__(self, message: str, code: str = "embedding_failed"):
        super().__init__(message)
        self.code = code


def _http_embedding_error(response: httpx.Response) -> EmbeddingUnavailableError:
    # Classify the server detail, but never expose its raw body (which may
    # contain submitted text) or httpx's diagnostic URL in the user interface.
    try:
        detail = str(response.json().get("error", "")).lower()
    except (ValueError, AttributeError):
        detail = ""
    if any(term in detail for term in ("too large to process", "input length exceeds", "context length", "context window")):
        return EmbeddingUnavailableError("The embedding model rejected the text length.", "embedding_input_too_long")
    if response.status_code == 404:
        return EmbeddingUnavailableError("The embedding model or API is unavailable. Check the selected model and Ollama version.", "embedding_model_unavailable")
    return EmbeddingUnavailableError("Ollama could not calculate the search vector. Check Ollama and try again.", "embedding_server_error")


async def get_embedding(
    text: str,
    model: Optional[str] = None,
    base_url: Optional[str] = None,
) -> list[float]:
    """Embed the first 8,000 characters with model-aware token truncation.

    The character cap bounds request size only. /api/embed applies the actual
    model token limit; the legacy /api/embeddings endpoint did not, so a single
    long Reader text could abort an entire index rebuild.
    """
    if not text or not text.strip():
        raise EmbeddingUnavailableError("Empty text — cannot embed.")

    if not ai_policy.enabled():
        raise EmbeddingUnavailableError("AI is disabled")
    policy_generation = ai_policy.generation()
    model = model or _active_model
    base_url = base_url or _active_base_url

    payload = {"model": model, "input": text[:8_000], "truncate": True}
    try:
        async with httpx.AsyncClient(timeout=TIMEOUT) as client:
            resp = await client.post(f"{base_url}/api/embed", json=payload)
            resp.raise_for_status()
            data = resp.json()
    except httpx.ConnectError:
        raise EmbeddingUnavailableError(
            f"Couldn't reach Ollama at {base_url}. "
            "Make sure it's running to use semantic search.", "embedding_connection"
        )
    except httpx.TimeoutException as error:
        raise EmbeddingUnavailableError("Ollama took too long to calculate the search vector.", "embedding_timeout") from error
    except httpx.HTTPStatusError as error:
        raise _http_embedding_error(error.response) from error
    except Exception as error:
        raise EmbeddingUnavailableError("Ollama returned an invalid embedding response.", "embedding_invalid_response") from error

    if not ai_policy.enabled() or policy_generation != ai_policy.generation():
        raise EmbeddingUnavailableError("AI configuration changed")
    vectors = data.get("embeddings") if isinstance(data, dict) else None
    if (not isinstance(vectors, list) or len(vectors) != 1
            or not isinstance(vectors[0], list) or not vectors[0]
            or not all(type(value) in (float, int) and math.isfinite(value) for value in vectors[0])):
        raise EmbeddingUnavailableError("Ollama returned an invalid search vector.", "embedding_invalid_response")
    return vectors[0]


async def get_embeddings(
    texts: list[str],
    model: Optional[str] = None,
    base_url: Optional[str] = None,
    progress: Callable[[int, int], None] | None = None,
    after_batch: Callable[[float], Awaitable[None]] | None = None,
) -> list[list[float]]:
    """Embed bounded batches, preserving order and reporting completed items."""
    cleaned = [text[:4_000] for text in texts if text and text.strip()]
    if len(cleaned) != len(texts) or not cleaned:
        raise EmbeddingUnavailableError("Every taxonomy item needs text to embed.")

    if not ai_policy.enabled():
        raise EmbeddingUnavailableError("AI is disabled")
    policy_generation = ai_policy.generation()
    model = model or _active_model
    base_url = base_url or _active_base_url
    # Taxonomy generation immediately switches to a language model. Ask Ollama
    # to release the embedding model after this response so both do not occupy
    # memory at once.
    vectors = []
    dimensions = None
    try:
        async with httpx.AsyncClient(timeout=180.0) as client:
            for offset in range(0, len(cleaned), EMBEDDING_BATCH_SIZE):
                if not ai_policy.enabled() or policy_generation != ai_policy.generation():
                    raise EmbeddingUnavailableError("AI configuration changed")
                batch = cleaned[offset:offset + EMBEDDING_BATCH_SIZE]
                payload = {
                    "model": model, "input": batch, "truncate": True,
                    # Keep the model resident between batches, release it before LLM work.
                    "keep_alive": 0 if offset + len(batch) == len(cleaned) else "5m",
                }
                started = time.monotonic()
                resp = await client.post(f"{base_url}/api/embed", json=payload)
                resp.raise_for_status()
                data = resp.json()
                batch_vectors = data.get("embeddings")
                if (not isinstance(batch_vectors, list) or len(batch_vectors) != len(batch)
                        or not all(isinstance(v, list) and v for v in batch_vectors)):
                    raise EmbeddingUnavailableError(f"Ollama returned incomplete embeddings for model '{model}'.")
                dimensions = dimensions or len(batch_vectors[0])
                if any(len(v) != dimensions for v in batch_vectors):
                    raise EmbeddingUnavailableError("Ollama returned inconsistent embedding dimensions.")
                if not ai_policy.enabled() or policy_generation != ai_policy.generation():
                    raise EmbeddingUnavailableError("AI configuration changed")
                vectors.extend(batch_vectors)
                if progress:
                    progress(len(vectors), len(cleaned))
                if after_batch:
                    await after_batch(time.monotonic() - started)
    except httpx.ConnectError:
        raise EmbeddingUnavailableError(
            f"Couldn't reach Ollama at {base_url}. Make sure it's running."
        )
    except httpx.TimeoutException:
        raise EmbeddingUnavailableError(
            "Ollama took too long to analyze the selected bookmarks."
        )
    except EmbeddingUnavailableError:
        raise
    except Exception as exc:
        raise EmbeddingUnavailableError(f"Embedding request failed: {exc}")

    if not ai_policy.enabled() or policy_generation != ai_policy.generation():
        raise EmbeddingUnavailableError("AI configuration changed")
    return vectors


def configuration_key():
    import json
    model = _active_model if ":" in _active_model else _active_model + ":latest"
    # /api/embed normalizes vectors. Do not mix them with an index generated
    # by the legacy endpoint: sqlite-vec uses Euclidean distance here.
    return json.dumps([_active_base_url.rstrip("/"), model, "embed-v2"])
