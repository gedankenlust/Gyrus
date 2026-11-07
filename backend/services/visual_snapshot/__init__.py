"""Design inspection ("visual snapshot") of a bookmarked website.

The package is layered so that each concern can change on its own:

* ``config``      - schema version, viewport presets, limits and timeouts.
* ``browser``     - the Chromium session: launch behind the egress proxy,
                    per-viewport contexts, request guard, bounded evaluate,
                    screenshot, teardown.
* ``recorder``    - Playwright event listeners that observe network, console
                    and loaded scripts while a viewport renders.
* ``navigation``  - menu exploration (hover/click) on the rendered page.
* ``extraction``  - the JavaScript injected into the page and the split of its
                    raw result into document data and technology signals.
* ``analysis``    - pure functions over extracted data (technologies, colors,
                    network, navigation merging). No Playwright, no files:
                    this is where audits and token export belong.
* ``imaging``     - artifacts derived from the screenshot file (palette,
                    evidence crops).
* ``document``    - assembles the JSON document the Swift app decodes
                    (Gyrus/Models/VisualSnapshotDTOs.swift). Its shape is a
                    contract.
* ``persistence`` - paths, run ids, run history, promotion and pruning rules,
                    atomic writes.
* ``capture``     - orchestrates one inspection across the viewports.

``services.visual_snapshot_service`` remains the public façade; callers
outside this package import from there.
"""
