#!/usr/bin/env python3
"""Stdio MCP server that exposes the bridge's quota windows to coding CLIs.

It reads `GET /v1/status` from the mac-app bridge (or `elink-tui` in local
mode) and returns only quota: no token counts, costs, sessions, or projects.
"""
from __future__ import annotations

import json
import os
import sys
import time
from datetime import datetime, timezone
from http.client import HTTPException
from urllib.request import ProxyHandler, build_opener

BRIDGE_URL = os.environ.get("ELINK_BRIDGE_URL", "http://127.0.0.1:8765")
SERVER_INFO = {"name": "elink-ai", "version": "1.0.0"}
PROTOCOL_VERSIONS = ("2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05")
PROVIDERS = ("claude", "codex", "gemini")
# The bridge names Claude's windows after their length and the others after
# their role. The short window is not always five hours (Gemini's can be a
# day), so the output keeps the neutral name `primary`.
WINDOW_PREFIXES = {
    "claude": ("five_hour", "seven_day"),
    "codex": ("primary", "weekly"),
    "gemini": ("primary", "weekly"),
}

TOOL = {
    "name": "get_usage_limits",
    "description": (
        "Current subscription quota for Claude, Codex and Gemini, as reported by "
        "the elink-ai bridge. With Multi-Host Sync the figures may come from another "
        "host, which may be signed in to a different account. Each provider has a primary window "
        "(the short rolling limit: five hours for Claude and Codex, five hours or "
        "a day for Gemini) and a weekly window, each with used_pct (percent "
        "already used; 100 or more means exhausted) and an approximate reset time. Use it when asked how much quota is left, or before choosing "
        "which agent should take on a large task. null means unknown, not zero."
    ),
    "inputSchema": {
        "type": "object",
        "properties": {
            "provider": {
                "type": "string",
                "enum": list(PROVIDERS),
                "description": "Only this provider; omit for all three.",
            }
        },
        "additionalProperties": False,
    },
}


class InvalidParams(Exception):
    pass


def fetch_status() -> dict:
    url = BRIDGE_URL.rstrip("/") + "/v1/status"
    # The bridge is on this machine or the LAN; a shell's http_proxy must not
    # route it through a proxy that cannot reach it.
    with build_opener(ProxyHandler({})).open(url, timeout=3) as response:
        return json.load(response)


def iso(epoch: float) -> str:
    return datetime.fromtimestamp(epoch, timezone.utc).isoformat().replace("+00:00", "Z")


def window(pct, reset_min, anchor, now: float) -> dict:
    # reset_min is whole minutes left when the bridge built the snapshot
    # (generated_at), already rounded down: subtract only whole minutes since.
    if reset_min is None or not anchor:
        return {"used_pct": pct, "resets_at": None, "resets_in_min": None}
    elapsed_min = int(max(0, now - anchor) // 60)
    if elapsed_min > reset_min:
        # The window has certainly reset since the snapshot (elink-tui serves
        # one until its next poll): the old usage says nothing about the new one.
        return {"used_pct": None, "resets_at": None, "resets_in_min": None}
    return {
        "used_pct": pct,
        "resets_at": iso(anchor + reset_min * 60),
        "resets_in_min": reset_min - elapsed_min,
    }


def provider_limits(name: str, raw, anchor, now: float) -> dict:
    if not isinstance(raw, dict):
        # Older bridges omit gemini: same shape, every value unknown.
        raw = {"error": "provider not reported by this bridge"}
    short, weekly = WINDOW_PREFIXES[name]
    extra = raw.get("extra_usage")
    fetched_at = raw.get("provider_usage_fetched_at")
    return {
        # Older bridges omit the per-provider fetch time: the age is unknown then.
        "data_age_s": max(0, int(now - fetched_at)) if fetched_at else None,
        "primary": window(raw.get(f"{short}_pct"), raw.get(f"{short}_reset_min"), anchor, now),
        "weekly": window(raw.get(f"{weekly}_pct"), raw.get(f"{weekly}_reset_min"), anchor, now),
        "scoped_limits": [
            {"title": item.get("title"), **window(item.get("pct"), item.get("reset_min"), anchor, now)}
            for item in raw.get("scoped_limits") or []
        ],
        "extra_usage": None if extra is None else {
            "used": extra.get("used"), "limit": extra.get("limit"),
            "used_pct": extra.get("pct"), "unit": extra.get("unit"),
        },
        "credit_balance": raw.get("credit_balance"),
        "error": raw.get("error"),
    }


def usage_limits(status: dict, provider: str | None, now: float) -> dict:
    anchor = status.get("generated_at")
    names = (provider,) if provider else PROVIDERS
    return {"providers": {name: provider_limits(name, status.get(name), anchor, now) for name in names}}


def call_tool(params: dict) -> dict:
    if params.get("name") != TOOL["name"]:
        raise InvalidParams(f"unknown tool: {params.get('name')}")
    arguments = params.get("arguments")
    arguments = {} if arguments is None else arguments
    if not isinstance(arguments, dict) or set(arguments) - {"provider"}:
        raise InvalidParams("arguments must be an object with at most a provider")
    provider = arguments.get("provider")
    if "provider" in arguments and provider not in PROVIDERS:
        raise InvalidParams(f"provider must be one of {', '.join(PROVIDERS)}")
    try:
        status = fetch_status()
        # v1 always carries claude and codex; gemini is optional on older bridges.
        # Anything else (e.g. elink-tui's Lighthouse /v1/status) is the wrong service.
        if not (isinstance(status, dict) and status.get("schema_version") == 1
                and isinstance(status.get("claude"), dict) and isinstance(status.get("codex"), dict)):
            raise ValueError("response is not a v1 quota snapshot")
    except (OSError, ValueError, HTTPException) as error:
        message = (f"elink-ai bridge unreachable at {BRIDGE_URL}: {error}. "
                   "Is the mac-app (or elink-tui) running?")
        return {"content": [{"type": "text", "text": message}], "isError": True}
    result = usage_limits(status, provider, time.time())
    return {
        "content": [{"type": "text", "text": json.dumps(result, ensure_ascii=False)}],
        "structuredContent": result,
    }


def handle(message) -> dict | None:
    """Return the JSON-RPC response for one message, or None for notifications."""
    if not isinstance(message, dict):
        return error_response(None, -32600, "invalid request: not an object")
    if "method" not in message:
        if "result" in message or "error" in message:
            return None  # a response to a request we never send
        return error_response(message.get("id"), -32600, "invalid request: missing method")
    if "id" not in message:
        return None
    request_id = message["id"]
    method = message["method"]
    params = message.get("params") or {}
    try:
        if not isinstance(params, dict):
            raise InvalidParams("params must be an object")
        if method == "initialize":
            requested = params.get("protocolVersion")
            result = {
                "protocolVersion": requested if requested in PROTOCOL_VERSIONS else PROTOCOL_VERSIONS[0],
                "capabilities": {"tools": {}},
                "serverInfo": SERVER_INFO,
            }
        elif method == "ping":
            result = {}
        elif method == "tools/list":
            result = {"tools": [TOOL]}
        elif method == "tools/call":
            result = call_tool(params)
        else:
            return error_response(request_id, -32601, f"method not found: {method}")
    except InvalidParams as error:
        return error_response(request_id, -32602, str(error))
    except Exception as error:  # a malformed request or bridge reply fails one call, not the session
        return error_response(request_id, -32603, f"internal error: {error}")
    return {"jsonrpc": "2.0", "id": request_id, "result": result}


def error_response(request_id, code: int, message: str) -> dict:
    return {"jsonrpc": "2.0", "id": request_id, "error": {"code": code, "message": message}}


def main() -> None:
    # MCP stdio is UTF-8 whatever the host locale or PYTHONIOENCODING says.
    sys.stdin.reconfigure(encoding="utf-8")
    sys.stdout.reconfigure(encoding="utf-8")
    for line in sys.stdin:
        if not line.strip():
            continue
        try:
            message = json.loads(line)
        except ValueError:
            response = error_response(None, -32700, "parse error")
        else:
            if message == []:
                response = error_response(None, -32600, "invalid request: empty batch")
            elif isinstance(message, list):  # JSON-RPC batch, allowed by protocol 2025-03-26
                response = [reply for item in message if (reply := handle(item)) is not None] or None
            else:
                response = handle(message)
        if response is not None:
            sys.stdout.write(json.dumps(response) + "\n")
            sys.stdout.flush()


if __name__ == "__main__":
    main()
