"""Make attribute patches on the façade module reach the layer that uses them.

``services.visual_snapshot_service`` re-exports names from the layer modules.
Callers and tests have always tuned the capture by assigning to the façade
(``monkeypatch.setattr(visual_snapshot_service, "SNAPSHOT_DIR", tmp)``,
``EVALUATE_TIMEOUT_SECONDS``, ``_capture_rendered_navigation`` ...). With the
code split into layers, a plain module attribute would change only the
façade's copy and the layer would keep using the original.

The rule is narrow: when a façade attribute is replaced, every layer module
that holds *the same object* under the corresponding name gets the new value
too. Names the façade defines itself, and layer names bound to something
else, are untouched. Restoring the attribute (monkeypatch undo) is just
another replacement, so it propagates the same way.
"""

import sys
import types
from typing import Iterable, Mapping

_MISSING = object()


def forward_attribute_patches(
    facade_name: str,
    layers: Iterable[types.ModuleType],
    aliases: Mapping[str, str] | None = None,
) -> None:
    """Install the forwarding on ``sys.modules[facade_name]``.

    ``aliases`` maps a façade name to the layer's name for the same object
    when they differ (e.g. ``_run_dir`` -> ``run_dir``).
    """
    layer_modules = tuple(layers)
    alias_map = dict(aliases or {})

    class _ForwardingFacade(types.ModuleType):
        def __setattr__(self, name: str, value) -> None:
            previous = self.__dict__.get(name, _MISSING)
            super().__setattr__(name, value)
            if previous is _MISSING or previous is value:
                return
            layer_name = alias_map.get(name, name)
            for layer in layer_modules:
                if layer.__dict__.get(layer_name, _MISSING) is previous:
                    setattr(layer, layer_name, value)

    sys.modules[facade_name].__class__ = _ForwardingFacade
