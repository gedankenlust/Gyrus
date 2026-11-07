"""Merging navigation trees read from successive DOM states."""

from typing import Any


def merge_navigation_groups(
    target: list[dict[str, Any]],
    incoming: list[dict[str, Any]],
) -> list[dict[str, Any]]:
    """Fold ``incoming`` into ``target`` (in place) and return ``target``.

    Menus mount their children only while open, so every revealed state adds
    children to items already seen. Items are matched by (url, label) so a
    parent keeps its place while its submenu grows.
    """

    def merge_items(existing: list[dict[str, Any]], additions: list[dict[str, Any]]) -> None:
        by_key = {
            (item.get("url") or "", item.get("label") or ""): item
            for item in existing
        }
        for addition in additions:
            key = (addition.get("url") or "", addition.get("label") or "")
            item = by_key.get(key)
            if item is None:
                item = {
                    "label": addition.get("label") or addition.get("url") or "",
                    "url": addition.get("url") or "",
                    "children": [],
                }
                existing.append(item)
                by_key[key] = item
            merge_items(item["children"], addition.get("children") or [])

    groups = {group.get("label") or "Navigation": group for group in target}
    for addition in incoming:
        label = addition.get("label") or "Navigation"
        group = groups.get(label)
        if group is None:
            group = {"label": label, "items": []}
            target.append(group)
            groups[label] = group
        merge_items(group["items"], addition.get("items") or [])
    return target
