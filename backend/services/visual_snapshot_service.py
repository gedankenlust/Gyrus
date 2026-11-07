"""Public façade for design inspections (visual snapshots).

The implementation lives in the ``services.visual_snapshot`` package (see its
docstring for the layers). This module re-exports the names callers and tests
import from here.

The re-exports are plain module attributes: assigning to one changes only the
façade's copy, never the layer that reads the name. Tests therefore patch the
layer module that uses a name at runtime (``persistence.SNAPSHOT_DIR``,
``browser.EVALUATE_TIMEOUT_SECONDS``, ``capture.capture_rendered_navigation``
...). Replacing a re-exported *function* here still works for callers that
look it up on the façade at call time (``visual_snapshot_service.capture_snapshot``).
"""

import logging

from services.visual_snapshot import (
    browser as _browser,
    extraction as _extraction,
    imaging as _imaging,
    persistence as _persistence,
)
from services.visual_snapshot.analysis import (
    navigation as _navigation_analysis,
    technologies as _technologies,
)
from services.visual_snapshot.config import (
    CONTEXT_CLOSE_TIMEOUT_SECONDS,
    DESIGN_INSPECTION_STEPS,
    MAX_CONSOLE_MESSAGES,
    MAX_NETWORK_ENTRIES,
    MAX_PRIMARY_SCRIPT_PROBES,
    MAX_SCREENSHOT_CSS_HEIGHT,
    MAX_SCREENSHOT_FILE_BYTES,
    MAX_SCREENSHOT_PIXELS,
    MAX_TECHNOLOGY_SCRIPT_BYTES,
    MAX_TECHNOLOGY_SCRIPT_PROBES,
    MAX_TECHNOLOGY_SCRIPT_TOTAL_BYTES,
    NAVIGATION_EXPLORATION_TIMEOUT_SECONDS,
    SNAPSHOT_SCHEMA_VERSION,
    VIEWPORTS,
)
from services.visual_snapshot.browser import VisualSnapshotUnavailable
from services.visual_snapshot.capture import capture_snapshot
from services.visual_snapshot.persistence import (
    SNAPSHOT_DIR,
    discard_snapshot_run,
    list_snapshot_runs,
    new_snapshot_run_id,
    read_snapshot,
    read_snapshot_run,
    snapshot_path,
    snapshot_summary,
)

logger = logging.getLogger(__name__)

# --- former module-private helpers that tests still call directly ----------
# Names that existed here only to be patched (EVALUATE_TIMEOUT_SECONDS,
# MAX_SNAPSHOT_RUNS, validate_outbound_url, _capture_rendered_navigation ...)
# are gone on purpose: a patch on them would now silently do nothing, while a
# missing attribute makes monkeypatch.setattr fail loudly.
_bounded_screenshot_height = _browser.bounded_screenshot_height
_script_content_markers = _technologies.script_content_markers
_script_technology_versions = _technologies.script_technology_versions
_declared_script_size = _technologies.declared_script_size
_is_primary_script_bundle = _technologies.is_primary_script_bundle
_detect_technologies = _technologies.detect_technologies
_run_dir = _persistence.run_dir
_prune_snapshot_runs = _persistence.prune_snapshot_runs
_attach_issue_evidence = _imaging.attach_issue_evidence
_dominant_colors = _imaging.dominant_colors
_merge_navigation_groups = _navigation_analysis.merge_navigation_groups
_VISUAL_EXTRACTOR_JS = _extraction.VISUAL_EXTRACTOR_JS

__all__ = [
    "DESIGN_INSPECTION_STEPS",
    "SNAPSHOT_DIR",
    "SNAPSHOT_SCHEMA_VERSION",
    "VIEWPORTS",
    "VisualSnapshotUnavailable",
    "capture_snapshot",
    "discard_snapshot_run",
    "list_snapshot_runs",
    "new_snapshot_run_id",
    "read_snapshot",
    "read_snapshot_run",
    "snapshot_path",
    "snapshot_summary",
]
