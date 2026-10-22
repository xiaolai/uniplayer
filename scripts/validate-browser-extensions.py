#!/usr/bin/env python3
"""Fail when a browser extension manifest names a file that does not exist."""

from __future__ import annotations

import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
BROWSER_ROOT = ROOT / "browser"


def referenced_files(manifest: dict) -> set[str]:
    files: set[str] = set()

    background = manifest.get("background", {})
    if isinstance(background, dict):
        for key in ("service_worker", "page"):
            if isinstance(background.get(key), str):
                files.add(background[key])
        for script in background.get("scripts", []):
            files.add(script)

    action = manifest.get("action") or manifest.get("browser_action") or {}
    if isinstance(action, dict):
        icon = action.get("default_icon")
        if isinstance(icon, str):
            files.add(icon)
        elif isinstance(icon, dict):
            files.update(icon.values())
        if isinstance(action.get("default_popup"), str):
            files.add(action["default_popup"])

    options = manifest.get("options_ui", {})
    if isinstance(options, dict) and isinstance(options.get("page"), str):
        files.add(options["page"])
    if isinstance(manifest.get("options_page"), str):
        files.add(manifest["options_page"])

    icons = manifest.get("icons", {})
    if isinstance(icons, dict):
        files.update(icons.values())

    for script in manifest.get("content_scripts", []):
        files.update(script.get("js", []))
        files.update(script.get("css", []))

    return {name for name in files if isinstance(name, str)}


def main() -> int:
    findings: list[str] = []
    manifests = sorted(BROWSER_ROOT.glob("*/manifest.json"))
    if not manifests:
        print("No browser extension manifests found.", file=sys.stderr)
        return 1

    for path in manifests:
        try:
            manifest = json.loads(path.read_text(encoding="utf-8"))
        except json.JSONDecodeError as error:
            findings.append(f"{path.relative_to(ROOT)}: invalid JSON: {error}")
            continue

        for name in sorted(referenced_files(manifest)):
            if not (path.parent / name).is_file():
                findings.append(f"{path.relative_to(ROOT)}: missing {name}")

    for finding in findings:
        print(finding, file=sys.stderr)
    return 1 if findings else 0


if __name__ == "__main__":
    sys.exit(main())
