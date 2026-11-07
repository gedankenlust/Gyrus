"""From embeddings and model answers to tag groups. Pure functions."""
from __future__ import annotations

import math
from collections import defaultdict
from dataclasses import dataclass, field
from typing import Any

from services.taxonomy.prompting import NO_TAG
from services.taxonomy.vocabulary import canonical_key

MAX_CANDIDATES_PER_BOOKMARK = 12
# (minimum cosine score, minimum ratio to the primary's score) for the second
# and third ranked topic. Secondary topics must be nearly as close as the
# primary one, or every bookmark collects loosely related tags.
SECONDARY_TOPIC_THRESHOLDS = {2: (0.34, 0.88), 3: (0.36, 0.92)}


def taxonomy_limits(bookmark_count: int) -> tuple[int, int]:
    """(maximum tags, maximum one-off tags) for a selection of this size."""
    max_tags = min(40, max(6, round(math.sqrt(max(bookmark_count, 1)) * 3.5)))
    singleton_limit = min(8, max(2, round(max_tags * 0.2)))
    return max_tags, singleton_limit


def unit(vector: list[float]) -> list[float]:
    length = math.sqrt(sum(value * value for value in vector)) or 1.0
    return [value / length for value in vector]


def similarity(left: list[float], right: list[float]) -> float:
    return sum(a * b for a, b in zip(left, right))


def rank_candidates(vectors: list[list[float]], bookmark_count: int, labels: list[str]):
    """Per bookmark, the closest catalog labels as (score, label), best first.

    ``vectors`` holds the bookmark embeddings followed by one embedding per
    label. CPU-bound for large libraries; the caller runs it in a thread.
    """
    bookmark_vectors = [unit(vector) for vector in vectors[:bookmark_count]]
    category_vectors = [unit(vector) for vector in vectors[bookmark_count:]]
    candidate_count = min(MAX_CANDIDATES_PER_BOOKMARK, len(labels))
    return [sorted(
        ((similarity(vector, category_vectors[index]), label) for index, label in enumerate(labels)),
        reverse=True,
    )[:candidate_count] for vector in bookmark_vectors]


@dataclass
class AssignmentTally:
    """Tag groups accumulated over the classification batches."""

    grouped_keys: dict[str, list[str]] = field(default_factory=lambda: defaultdict(list))
    primary_counts: dict[str, int] = field(default_factory=lambda: defaultdict(int))
    assignment_scores: dict[str, list[float]] = field(default_factory=lambda: defaultdict(list))

    def add_chunk(
        self,
        keys: list[str],
        candidates: list[list[str]],
        rankings: list[list[tuple[float, str]]],
        payload: dict[str, Any],
    ) -> None:
        for key, allowed, ranked in zip(keys, candidates, rankings):
            allowed_by_key = {canonical_key(name): name for name in allowed}
            raw_name = payload.get(key, payload.get(f"{key}_1", NO_TAG))
            primary = allowed_by_key.get(canonical_key(str(raw_name)))
            if not primary:
                continue
            selected = [primary]
            self.primary_counts[primary] += 1

            # Add related secondary topics only when both methods agree on the
            # primary category. This avoids blindly attaching the embedding
            # model's tempting but wrong nearest neighbour after the LLM has
            # already corrected it (for example JUCE -> audio, not webdesign).
            top_score, top_name = ranked[0]
            if primary == top_name:
                for index, (score, name) in enumerate(ranked[1:3], start=2):
                    minimum_score, minimum_ratio = SECONDARY_TOPIC_THRESHOLDS[index]
                    if score >= minimum_score and score >= top_score * minimum_ratio:
                        selected.append(name)
            for name in selected:
                self.grouped_keys[name].append(key)
                score = next((value for value, candidate in ranked if candidate == name), 0.0)
                self.assignment_scores[name].append(score)


def limit_categories(grouped_keys: dict[str, list[str]],
                     primary_counts: dict[str, int],
                     assignment_scores: dict[str, list[float]],
                     max_tags: int) -> tuple[dict[str, list[str]], int]:
    """Keep the strongest categories instead of rejecting an oversized draft."""
    if len(grouped_keys) <= max_tags:
        return grouped_keys, 0

    def rank(name: str) -> tuple[int, int, float, str]:
        scores = assignment_scores.get(name, [])
        average_score = sum(scores) / len(scores) if scores else 0.0
        return (
            -primary_counts.get(name, 0),
            -len(grouped_keys[name]),
            -average_score,
            name.casefold(),
        )

    selected = set(sorted(grouped_keys, key=rank)[:max_tags])
    limited = {
        name: keys for name, keys in grouped_keys.items()
        if name in selected
    }
    return limited, len(grouped_keys) - len(limited)
