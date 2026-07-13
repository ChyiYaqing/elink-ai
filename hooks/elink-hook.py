#!/usr/bin/env python3
"""Forward one CLI hook event to the local bridge without delaying the CLI."""
from __future__ import annotations

import json
import sys
from urllib.request import Request, urlopen


def main() -> None:
    if len(sys.argv) != 3:
        return
    try:
        incoming = json.load(sys.stdin)
    except (json.JSONDecodeError, OSError):
        incoming = {}
    payload = {"agent": sys.argv[1], "event": sys.argv[2]}
    message = incoming.get("message") or incoming.get("notification")
    if isinstance(message, str):
        payload["message"] = message
    request = Request(
        "http://127.0.0.1:8765/v1/event",
        method="POST",
        data=json.dumps(payload).encode(),
        headers={"Content-Type": "application/json"},
    )
    try:
        urlopen(request, timeout=1).close()
    except OSError:
        pass


if __name__ == "__main__":
    main()
