"""Constants shared by the capture, analysis and persistence layers."""

# 7: Website inspection identifies first-party frontend building blocks and
#    cautiously infers static HTML / vanilla JavaScript when no application
#    framework is present. Keep in sync with
#    expectedSnapshotSchemaVersion in
#    Gyrus/Views/PreviewPanel/VisualSnapshotTabView.swift — the app compares the
#    two and offers a reinspect when a stored snapshot predates the current
#    capture.
SNAPSHOT_SCHEMA_VERSION = 7

MAX_TECHNOLOGY_SCRIPT_PROBES = 12
MAX_PRIMARY_SCRIPT_PROBES = 4
MAX_TECHNOLOGY_SCRIPT_BYTES = 2_000_000
MAX_TECHNOLOGY_SCRIPT_TOTAL_BYTES = 12_000_000
MAX_NETWORK_ENTRIES = 2_000
MAX_CONSOLE_MESSAGES = 200
MAX_SCREENSHOT_CSS_HEIGHT = 20_000
MAX_SCREENSHOT_PIXELS = 24_000_000
MAX_SCREENSHOT_FILE_BYTES = 30_000_000

VIEWPORTS = [
    {"name": "desktop", "width": 1440, "height": 900, "device_scale_factor": 1},
    {"name": "tablet", "width": 834, "height": 1112, "device_scale_factor": 2},
    {"name": "mobile", "width": 390, "height": 844, "device_scale_factor": 2},
]
TOUCH_VIEWPORTS = frozenset({"tablet", "mobile"})
# One step per viewport plus the website structure crawl.
DESIGN_INSPECTION_STEPS = len(VIEWPORTS) + 1

# Page scripts run on the renderer's main thread; a busy-looping page would
# otherwise block page.evaluate (and the whole inspection job) forever.
EVALUATE_TIMEOUT_SECONDS = 20.0
NAVIGATION_EXPLORATION_TIMEOUT_SECONDS = 60.0
CONTEXT_CLOSE_TIMEOUT_SECONDS = 10.0
PAGE_LOAD_TIMEOUT_MS = 30_000
NETWORK_IDLE_TIMEOUT_MS = 5_000
SCREENSHOT_TIMEOUT_SECONDS = 20.0
SCRIPT_BODY_TIMEOUT_SECONDS = 5.0
