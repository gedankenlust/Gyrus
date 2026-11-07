"""Global, review-first taxonomy generation for bookmark batches.

Façade over ``services.taxonomy`` (see its docstring for the layers). It
keeps every name callers and tests have used from this module, and it owns
the pipeline that wires the layers together (``generate_draft``). The
pipeline calls its collaborators through this module's globals, so patching
``taxonomy_service._stream_taxonomy``, ``CLASSIFICATION_BATCH_SIZE`` and the
like keeps working.
"""
from __future__ import annotations

import asyncio
import json
import time
from typing import Any, Callable

from sqlalchemy.orm import Session

from models.bookmark import Bookmark
from models.tag import Tag
from services import ai_policy, embedding_service, llm_service
from services.tagging_pacer import TaggingPacer
from services.taxonomy.apply import apply_draft
from services.taxonomy.assignment import (
    AssignmentTally,
    limit_categories as _limit_categories,
    rank_candidates as _rank_candidates,
    similarity as _similarity,
    taxonomy_limits,
    unit as _unit,
)
from services.taxonomy.drafts import (
    _drafts,
    discard_draft,
    max_category_size as _max_category_size,
    minimum_reusable_groups as _minimum_reusable_groups,
    parse_taxonomy,
    remember_draft,
)
from services.taxonomy.errors import TaxonomyQualityError
from services.taxonomy.prompting import (
    CLASSIFICATION_BATCH_SIZE,
    CLASSIFICATION_TIMEOUT,
    MAX_EXCERPT_CHARS,
    NO_TAG,
    _UNSUPPORTED_TAXONOMY_MODELS,
    assert_taxonomy_model_supported as _assert_taxonomy_model_supported,
    category_texts,
    checked_classification as _checked_classification,
    classification_payload as _classification_payload,
    classification_prompt as _classification_prompt,
    classification_records as _classification_records,
    classification_schema as _classification_schema,
    compact_records,
    embedding_texts,
    json_document as _json_document,
    json_payload as _json_payload,
    repair_prompt,
    repair_records,
    stream_taxonomy as _stream_taxonomy,
)
from services.taxonomy.vocabulary import (
    MAX_NAME_CHARS,
    MAX_TAGS_PER_BOOKMARK,
    MAX_WORDS,
    _ALIASES,
    _BROAD_TAGS,
    _PLURAL_EXCEPTIONS,
    canonical_key as _canonical_key,
    canonical_tag_key,
    classification_catalog as _classification_catalog,
    flat as _flat,
    is_reusable_label as _is_reusable_label,
    normalize_tag_name,
)
from services.taxonomy_checkpoint import ClassificationCheckpoint

__all__ = [
    "MAX_EXCERPT_CHARS",
    "TaxonomyQualityError",
    "apply_draft",
    "canonical_tag_key",
    "compact_records",
    "discard_draft",
    "generate_draft",
    "normalize_tag_name",
    "parse_taxonomy",
    "taxonomy_limits",
]


def _manual_tag_names(db: Session) -> list[str]:
    return [
        name for (name,) in db.query(Tag.name).filter(Tag.source == "manual").order_by(Tag.name).all()
    ]


def _policy_changed(policy_generation: int) -> bool:
    return not ai_policy.enabled() or policy_generation != ai_policy.generation()


async def _classify_chunk(
    chunk_keys: list[str],
    chunk_records: str,
    schema: dict[str, Any],
    config: dict[str, Any],
    language: str | None,
    progress: Callable[[str, int], None] | None,
    *,
    offset: int,
    total: int,
    policy_generation: int,
) -> tuple[dict[str, Any], bool]:
    """Classify one batch; return (payload, whether the batch failed in format).

    A timeout affects this chunk only and is retried once. Prior chunks are
    durable and are reused when the same selection/configuration is tried
    again, which the error message tells the user.
    """
    for attempt in range(2):
        try:
            async with asyncio.timeout(CLASSIFICATION_TIMEOUT):
                raw = await _stream_taxonomy(
                    _classification_prompt(language), chunk_records, config, language,
                    "assigning", progress, schema,
                )
                try:
                    return _checked_classification(raw, chunk_keys), False
                except TaxonomyQualityError:
                    repaired = await _stream_taxonomy(
                        repair_prompt(language),
                        repair_records(chunk_records, raw),
                        config, language, "repairing", progress, schema,
                    )
                    return _checked_classification(repaired, chunk_keys), False
        except TaxonomyQualityError:
            return {}, True
        except (TimeoutError, llm_service.LLMUnavailableError) as error:
            if _policy_changed(policy_generation):
                raise
            if attempt == 1:
                message = (
                    f"KI-Anfrage abgebrochen nach {offset}/{total} Lesezeichen. "
                    "Erneut starten: fertige Zuordnungsblöcke werden wiederverwendet."
                    if language == "de" else
                    f"AI request stopped after {offset}/{total} bookmarks. "
                    "Start again to reuse completed classification batches."
                )
                detail = str(error).strip() or ("Zeitlimit erreicht." if language == "de" else "Time limit reached.")
                raise llm_service.LLMUnavailableError(f"{message} {detail}") from error
    # Not reached: the last attempt either returns or raises.
    return {}, True


async def generate_draft(db: Session, bookmarks: list[Bookmark], provider_config: dict | None,
                         language: str | None,
                         progress: Callable[[str, int], None] | None = None) -> dict[str, Any]:
    policy_generation = ai_policy.generation()
    _, keyed = compact_records(bookmarks)
    max_tags, singleton_limit = taxonomy_limits(len(bookmarks))
    # Sync SQLAlchemy; the engine allows use from a worker thread
    # (check_same_thread=False) and nothing else touches this session meanwhile.
    existing_tags = await asyncio.to_thread(_manual_tag_names, db)
    config = provider_config or {"provider": "ollama", "model": "llama3"}
    _assert_taxonomy_model_supported(config)
    pacer = TaggingPacer(config.get("gentle_tagging") is True, progress)
    base_url = config.get("ollama_url") or config.get("base_url") or "http://localhost:11434"
    embedding_model = config.get("embedding_model") or embedding_service.current_model()

    catalog = _classification_catalog(language, existing_tags)
    labels = list(catalog)
    bookmark_keys = list(keyed)

    if progress:
        progress("embedding", 0)
    vectors = await embedding_service.get_embeddings(
        embedding_texts(bookmarks) + category_texts(catalog),
        model=embedding_model,
        base_url=base_url,
        progress=lambda done, total: progress("embedded", min(done, len(bookmarks))) if progress else None,
        after_batch=lambda duration: pacer.rest(duration, "embedding"),
    )
    if progress:
        progress("clustering", 0)
    ranked_candidates = await asyncio.to_thread(_rank_candidates, vectors, len(bookmarks), labels)
    candidates = [
        [label for _, label in ranked]
        for ranked in ranked_candidates
    ]
    records = _classification_records(bookmarks, bookmark_keys, candidates)

    # The checkpoint reads (and prunes) earlier checkpoint files on creation.
    checkpoint = await asyncio.to_thread(ClassificationCheckpoint, {
        "version": 2, "records": records, "keys": bookmark_keys,
        "model": config.get("model"), "embedding_model": embedding_model,
        "base_url": base_url, "language": language, "batch_size": CLASSIFICATION_BATCH_SIZE,
        "prompt": _classification_prompt(language),
    })
    tally = AssignmentTally()
    failed_batches = 0
    for offset in range(0, len(bookmarks), CLASSIFICATION_BATCH_SIZE):
        chunk_keys = bookmark_keys[offset:offset + CLASSIFICATION_BATCH_SIZE]
        chunk_candidates = candidates[offset:offset + CLASSIFICATION_BATCH_SIZE]
        chunk_records = "\n".join(records[offset:offset + CLASSIFICATION_BATCH_SIZE])
        schema = _classification_schema(chunk_keys, chunk_candidates)
        if _policy_changed(policy_generation):
            raise llm_service.LLMUnavailableError("AI configuration changed")
        payload = checkpoint.responses.get(str(offset))
        work_seconds = 0.0
        if payload is None:
            started = time.monotonic()
            payload, failed = await _classify_chunk(
                chunk_keys, chunk_records, schema, config, language, progress,
                offset=offset, total=len(bookmarks), policy_generation=policy_generation,
            )
            failed_batches += failed
            work_seconds = time.monotonic() - started
            if payload:
                await asyncio.to_thread(checkpoint.save, offset, payload)
        if progress:
            progress("classified", min(offset + CLASSIFICATION_BATCH_SIZE, len(bookmarks)))
        await asyncio.sleep(0)

        tally.add_chunk(
            chunk_keys,
            chunk_candidates,
            ranked_candidates[offset:offset + CLASSIFICATION_BATCH_SIZE],
            payload,
        )
        if work_seconds > 0 and offset + CLASSIFICATION_BATCH_SIZE < len(bookmarks):
            await pacer.rest(work_seconds, "assigning")

    grouped_keys, omitted_tags = _limit_categories(
        tally.grouped_keys, tally.primary_counts, tally.assignment_scores, max_tags,
    )

    # These are controlled, broad categories rather than model-invented labels.
    # They remain reusable even when only one selected bookmark currently fits
    # (for example amateur radio or career), so do not discard honest long-tail
    # assignments merely because this particular selection contains one item.
    taxonomy = [
        {"name": name, "bookmark_ids": keys}
        for name, keys in grouped_keys.items()
    ]
    if failed_batches and not taxonomy:
        raise TaxonomyQualityError(
            "The selected model could not classify the bookmarks in the required format."
        )
    try:
        draft = parse_taxonomy(
            json.dumps({"taxonomy": taxonomy}, ensure_ascii=False),
            keyed, max_tags, max(singleton_limit, len(taxonomy)), language,
        )
    finally:
        # Checkpoints resume interrupted work. Finished (including rejected)
        # results must not lock future fresh analyses to an old response.
        checkpoint.path.unlink(missing_ok=True)
    draft["omitted_tags"] = omitted_tags

    remember_draft(draft)
    return draft
