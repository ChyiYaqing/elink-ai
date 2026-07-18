#!/usr/bin/env python3
"""Merge elink-ai lifecycle hooks into Claude Code settings without replacing user hooks."""
from __future__ import annotations

import argparse
import json
import os
import shutil
import sys
from pathlib import Path

EVENTS = [
    "UserPromptSubmit", "PreToolUse", "PostToolUse", "Stop", "SessionEnd",
    "Notification", "PreCompact", "SubagentStop",
    "PermissionRequest", "Elicitation",
]


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--settings", type=Path, default=Path.home() / ".claude/settings.json")
    parser.add_argument("--helper-dir", type=Path, default=Path.home() / ".local/share/elink-ai")
    args = parser.parse_args()
    path = args.settings
    try:
        text = path.read_text()
    except FileNotFoundError:
        text = ""
    if not text.strip():
        settings = {}
    else:
        try:
            settings = json.loads(text)
        except json.JSONDecodeError as error:
            sys.exit(f"{path} is not valid JSON ({error}); fix or remove it, then rerun.")
        if not isinstance(settings, dict):
            sys.exit(f"{path} must contain a JSON object, not {type(settings).__name__}.")
    if settings.get("hooks") is None:
        settings["hooks"] = {}
    elif not isinstance(settings["hooks"], dict):
        sys.exit(f'"hooks" in {path} must be a JSON object; fix it manually, then rerun.')
    if path.exists():
        shutil.copy2(path, path.with_suffix(path.suffix + ".elink-ai.bak"))
    helper_dir = args.helper_dir
    helper_dir.mkdir(parents=True, exist_ok=True)
    helper_source = Path(__file__).with_name("elink-hook.py")
    helper_target = helper_dir / "elink-hook.py"
    shutil.copy2(helper_source, helper_target)
    hooks = settings["hooks"]
    for event in EVENTS:
        entries = hooks.setdefault(event, [])
        if "elink-hook.py" in json.dumps(entries):
            continue
        command = f"/usr/bin/python3 '{helper_target}' claude {event}"
        entries.append({"matcher": "", "hooks": [{"type": "command", "command": command}]})
    path.parent.mkdir(parents=True, exist_ok=True)
    # settings 可能包含敏感信息，不继承组/其他用户权限
    mode = 0o600
    temporary = path.with_suffix(path.suffix + ".tmp")
    fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, mode)
    with os.fdopen(fd, "w") as handle:
        handle.write(json.dumps(settings, ensure_ascii=False, indent=2) + "\n")
    os.chmod(temporary, mode)
    temporary.replace(path)
    print(f"Updated {path}; restart Claude Code to load hooks.")


if __name__ == "__main__":
    main()
