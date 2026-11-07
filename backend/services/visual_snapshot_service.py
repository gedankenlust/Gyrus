"""Public façade for design inspections (visual snapshots).

The implementation lives in the ``services.visual_snapshot`` package (see its
docstring for the layers). This module keeps every name callers and tests
have imported from here, and attribute patches on it reach the layer that
uses the name (see ``services.visual_snapshot._facade``).
"""

import logging

from services.atomic_write import atomic_write_text
from services.outbound_url_security import explicit_private_hostname, validate_outbound_url
from services.safe_egress_proxy import SafeEgressProxy
from services.visual_snapshot import (
    browser as _browser,
    capture as _capture,
    config as _config,
    document as _document,
    extraction as _extraction,
    imaging as _imaging,
    navigation as _navigation,
    persistence as _persistence,
    recorder as _recorder,
)
from services.visual_snapshot._facade import forward_attribute_patches
from services.visual_snapshot.analysis import (
    colors as _colors,
    navigation as _navigation_analysis,
    network as _network,
    technologies as _technologies,
)
from services.visual_snapshot.config import (
    CONTEXT_CLOSE_TIMEOUT_SECONDS,
    DESIGN_INSPECTION_STEPS,
    EVALUATE_TIMEOUT_SECONDS,
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
    MAX_SNAPSHOT_RUNS,
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

# --- former module-private helpers, kept for tests and patch targets -------
_evaluate = _browser.evaluate
_bounded_screenshot_height = _browser.bounded_screenshot_height
_TECHNOLOGY_RULES = _technologies._TECHNOLOGY_RULES
_SCRIPT_CONTENT_FINGERPRINTS = _technologies._SCRIPT_CONTENT_FINGERPRINTS
_script_content_markers = _technologies.script_content_markers
_script_technology_versions = _technologies.script_technology_versions
_declared_script_size = _technologies.declared_script_size
_is_primary_script_bundle = _technologies.is_primary_script_bundle
_detect_technologies = _technologies.detect_technologies
_bookmark_dir = _persistence.bookmark_dir
_runs_dir = _persistence.runs_dir
_run_dir = _persistence.run_dir
_prune_snapshot_runs = _persistence.prune_snapshot_runs
_attach_issue_evidence = _imaging.attach_issue_evidence
_dominant_colors = _imaging.dominant_colors
_network_summary = _network.network_summary
_network_item = _network.network_item
_merge_navigation_groups = _navigation_analysis.merge_navigation_groups
_capture_rendered_navigation = _navigation.capture_rendered_navigation
_NAVIGATION_EXTRACTOR_JS = _extraction.NAVIGATION_EXTRACTOR_JS
_VISUAL_EXTRACTOR_JS = _extraction.VISUAL_EXTRACTOR_JS

forward_attribute_patches(
    __name__,
    layers=(
        _config,
        _browser,
        _recorder,
        _navigation,
        _extraction,
        _document,
        _imaging,
        _persistence,
        _capture,
        _colors,
        _navigation_analysis,
        _network,
        _technologies,
    ),
    aliases={
        "_evaluate": "evaluate",
        "_bounded_screenshot_height": "bounded_screenshot_height",
        "_script_content_markers": "script_content_markers",
        "_script_technology_versions": "script_technology_versions",
        "_declared_script_size": "declared_script_size",
        "_is_primary_script_bundle": "is_primary_script_bundle",
        "_detect_technologies": "detect_technologies",
        "_bookmark_dir": "bookmark_dir",
        "_runs_dir": "runs_dir",
        "_run_dir": "run_dir",
        "_prune_snapshot_runs": "prune_snapshot_runs",
        "_attach_issue_evidence": "attach_issue_evidence",
        "_dominant_colors": "dominant_colors",
        "_network_summary": "network_summary",
        "_network_item": "network_item",
        "_merge_navigation_groups": "merge_navigation_groups",
        "_capture_rendered_navigation": "capture_rendered_navigation",
        "_NAVIGATION_EXTRACTOR_JS": "NAVIGATION_EXTRACTOR_JS",
        "_VISUAL_EXTRACTOR_JS": "VISUAL_EXTRACTOR_JS",
    },
)

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
