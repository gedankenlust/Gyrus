"""Global, review-first taxonomy generation for bookmark batches.

Layers:

* ``vocabulary`` - tag-name normalization, canonical keys, the broad tag
                   catalog and which labels count as reusable.
* ``prompting``  - records, schemas and prompts sent to the model, the
                   streaming LLM call, and parsing of its JSON replies.
* ``assignment`` - embedding similarity, candidate ranking and turning model
                   classifications into tag groups (pure).
* ``drafts``     - validating a taxonomy into a draft and the in-memory
                   store of drafts awaiting review.
* ``apply``      - writing an approved draft to the database.

``services.taxonomy_service`` is the façade and wires these together in
``generate_draft``; callers import from there.
"""
