import importlib.util
import json
import subprocess
import sys
import threading
import time
from http.client import IncompleteRead
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "mcp" / "elink-mcp.py"
FIXTURE = json.loads((ROOT / "fixtures" / "status-v1.json").read_text())

spec = importlib.util.spec_from_file_location("elink_mcp", SCRIPT)
elink_mcp = importlib.util.module_from_spec(spec)
spec.loader.exec_module(elink_mcp)

GENERATED = FIXTURE["generated_at"]


def call(arguments=None):
    return elink_mcp.handle({
        "jsonrpc": "2.0", "id": 7, "method": "tools/call",
        "params": {"name": "get_usage_limits", "arguments": arguments or {}},
    })


def test_normalizes_windows_counting_from_snapshot_time():
    status = json.loads(json.dumps(FIXTURE))
    status["claude"]["provider_usage_fetched_at"] = GENERATED - 600
    result = elink_mcp.usage_limits(status, None, now=GENERATED + 60)
    claude = result["providers"]["claude"]
    assert claude["primary"] == {
        "used_pct": 43.0,
        "resets_at": elink_mcp.iso(GENERATED + 87 * 60),
        "resets_in_min": 86,
    }
    # The bridge already rounded down; a fraction of a minute later is still 87.
    fresh = elink_mcp.usage_limits(status, "claude", now=GENERATED + 0.1)["providers"]["claude"]
    assert fresh["primary"]["resets_in_min"] == 87
    assert claude["weekly"]["used_pct"] == 68.0
    assert claude["scoped_limits"] == [
        {"title": "Opus", "used_pct": 61.0, "resets_at": elink_mcp.iso(GENERATED + 4320 * 60),
         "resets_in_min": 4319},
    ]
    assert claude["extra_usage"] == {"used": 10.3, "limit": 100.0, "used_pct": 10.3, "unit": "USD"}
    codex = result["providers"]["codex"]
    assert codex["primary"]["used_pct"] == 12.0
    assert codex["weekly"]["used_pct"] == 22.0
    assert codex["credit_balance"] == 1250.5
    # Freshness is per provider: the fixture's codex predates the field.
    assert claude["data_age_s"] == 660
    assert codex["data_age_s"] is None


def test_window_past_its_reset_reports_unknown_usage():
    status = {"generated_at": GENERATED, "claude": {"five_hour_pct": 97.0, "five_hour_reset_min": 5}}
    def primary(seconds_later):
        return elink_mcp.usage_limits(status, "claude", now=GENERATED + seconds_later)["providers"]["claude"]["primary"]
    # Up to a minute past the rounded-down reset, the window may still be open.
    assert primary(5 * 60 + 59)["used_pct"] == 97.0
    assert primary(5 * 60 + 59)["resets_in_min"] == 0
    assert primary(6 * 60) == {"used_pct": None, "resets_at": None, "resets_in_min": None}


def test_output_carries_only_quota():
    text = json.dumps(elink_mcp.usage_limits(FIXTURE, None, now=GENERATED))
    for leaked in ("tokens_today", "cost_today", "elink-ai", "session-claude-1", "needs_input"):
        assert leaked not in text


def test_provider_filter():
    result = elink_mcp.usage_limits(FIXTURE, "codex", now=GENERATED)
    assert list(result["providers"]) == ["codex"]


def test_bridge_without_gemini_reports_provider_missing():
    result = elink_mcp.usage_limits(FIXTURE, "gemini", now=GENERATED)
    gemini = result["providers"]["gemini"]
    assert gemini["error"] == "provider not reported by this bridge"
    assert gemini["primary"] == gemini["weekly"] == {"used_pct": None, "resets_at": None, "resets_in_min": None}
    assert gemini["data_age_s"] is None and gemini["extra_usage"] is None


def test_unknown_values_stay_null():
    status = {"generated_at": GENERATED,
              "claude": {"five_hour_pct": None, "five_hour_reset_min": None, "extra_usage": None}}
    claude = elink_mcp.usage_limits(status, "claude", now=GENERATED)["providers"]["claude"]
    assert claude["primary"] == {"used_pct": None, "resets_at": None, "resets_in_min": None}
    assert claude["weekly"]["used_pct"] is None
    assert claude["extra_usage"] is None


def test_tool_call_returns_structured_and_text_content(monkeypatch):
    monkeypatch.setattr(elink_mcp, "fetch_status", lambda: FIXTURE)
    result = call({"provider": "claude"})["result"]
    assert "isError" not in result
    assert json.loads(result["content"][0]["text"]) == result["structuredContent"]
    assert list(result["structuredContent"]["providers"]) == ["claude"]


def test_unreachable_bridge_is_a_tool_error(monkeypatch):
    def refuse():
        raise ConnectionRefusedError("refused")
    monkeypatch.setattr(elink_mcp, "fetch_status", refuse)
    result = call()["result"]
    assert result["isError"] is True
    assert "unreachable" in result["content"][0]["text"]


@pytest.mark.parametrize("bad_reply", [
    lambda: ["not", "an", "object"],
    lambda: {"schema_version": 2, "generated_at": 1, "hosts": [], "wan": []},  # Lighthouse
    lambda: (_ for _ in ()).throw(IncompleteRead(b"{")),
])
def test_bad_bridge_reply_is_a_tool_error(monkeypatch, bad_reply):
    monkeypatch.setattr(elink_mcp, "fetch_status", bad_reply)
    assert call()["result"]["isError"] is True


def test_malformed_bridge_fields_fail_one_call_only(monkeypatch):
    monkeypatch.setattr(elink_mcp, "fetch_status", lambda: {
        "schema_version": 1, "codex": {}, "claude": {"scoped_limits": [1]}})
    assert call({"provider": "claude"})["error"]["code"] == -32603


@pytest.mark.parametrize("params", [
    {"name": "get_usage_limits", "arguments": {"provider": "openai"}},
    {"name": "get_usage_limits", "arguments": "claude"},
    {"name": "get_usage_limits", "arguments": False},
    {"name": "get_usage_limits", "arguments": {"provider": None}},
    {"name": "get_usage_limits", "arguments": {"provder": "claude"}},
    {"name": "other_tool", "arguments": {}},
    ["not", "an", "object"],
])
def test_invalid_params(params):
    response = elink_mcp.handle({"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": params})
    assert response["error"]["code"] == -32602


def test_unknown_method_and_notifications():
    assert elink_mcp.handle({"jsonrpc": "2.0", "id": 2, "method": "resources/list"})["error"]["code"] == -32601
    assert elink_mcp.handle({"jsonrpc": "2.0", "method": "notifications/initialized"}) is None
    assert elink_mcp.handle({"jsonrpc": "2.0", "id": 3})["error"]["code"] == -32600
    assert elink_mcp.handle({"jsonrpc": "2.0", "id": 3, "result": {}}) is None
    assert elink_mcp.handle(5)["error"]["code"] == -32600


def test_initialize_negotiates_protocol_version():
    def negotiate(version):
        response = elink_mcp.handle({"jsonrpc": "2.0", "id": 1, "method": "initialize",
                                     "params": {"protocolVersion": version}})
        return response["result"]["protocolVersion"]
    assert negotiate("2025-06-18") == "2025-06-18"
    assert negotiate("1999-01-01") == elink_mcp.PROTOCOL_VERSIONS[0]


class FixtureHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        # A live bridge stamps each snapshot now; the fixture's date is long past.
        body = json.dumps({**FIXTURE, "generated_at": int(time.time())}).encode()
        self.send_response(200 if self.path == "/v1/status" else 404)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


def test_stdio_session_against_http_bridge():
    server = HTTPServer(("127.0.0.1", 0), FixtureHandler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    batch = json.dumps([{"jsonrpc": "2.0", "id": 4, "method": "ping"},
                        {"jsonrpc": "2.0", "method": "notifications/initialized"},
                        "bogus",
                        {"jsonrpc": "2.0", "id": 5, "method": "ping"}])
    messages = [
        {"jsonrpc": "2.0", "id": 1, "method": "initialize",
         "params": {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "终端", "version": "0"}}},
        {"jsonrpc": "2.0", "method": "notifications/initialized"},
        {"jsonrpc": "2.0", "id": 2, "method": "tools/list"},
        {"jsonrpc": "2.0", "id": 3, "method": "tools/call",
         "params": {"name": "get_usage_limits", "arguments": {"provider": "claude"}}},
    ]
    try:
        completed = subprocess.run(
            [sys.executable, str(SCRIPT)],
            input="".join(json.dumps(m) + "\n" for m in messages) + "null\nnot json\n" + batch + "\n[]\n",
            capture_output=True, text=True, encoding="utf-8", timeout=10, check=True,
            # A dead proxy proves the bridge request bypasses shell proxy settings.
            env={"ELINK_BRIDGE_URL": f"http://127.0.0.1:{server.server_port}",
                 "PYTHONIOENCODING": "ascii",
                 "http_proxy": "http://127.0.0.1:9", "no_proxy": ""},
        )
    finally:
        server.shutdown()
    responses = [json.loads(line) for line in completed.stdout.splitlines()]
    assert [r["id"] for r in responses[:5]] == [1, 2, 3, None, None]
    assert responses[3]["error"]["code"] == -32600  # the bare null
    assert [r.get("id") for r in responses[5]] == [4, None, 5]
    assert responses[5][1]["error"]["code"] == -32600
    assert responses[6]["error"]["code"] == -32600  # the empty batch
    assert responses[0]["result"]["serverInfo"]["name"] == "elink-ai"
    assert responses[1]["result"]["tools"][0]["name"] == "get_usage_limits"
    claude = responses[2]["result"]["structuredContent"]["providers"]["claude"]
    assert claude["primary"]["used_pct"] == 43.0
    assert responses[4]["error"]["code"] == -32700
