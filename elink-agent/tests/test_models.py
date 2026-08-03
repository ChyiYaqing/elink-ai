import json
from pathlib import Path

from elink_agent.models import StatusSnapshot


def test_parse_bridge_shape_and_preserve_overage_percentage():
    snapshot = StatusSnapshot.from_dict({
        "schema_version": 1,
        "generated_at": 123,
        "claude": {
            "status": "working",
            "tokens_today": 42,
            "model_usage_today": [
                {"model": "claude-sonnet", "tokens": 30},
                {"model": "claude-opus", "tokens": 12},
            ],
            "five_hour_pct": 125,
            "five_hour_reset_min": 30,
            "seven_day_pct": None,
            "needs_input": True,
        },
        "codex": {
            "status": "idle",
            "primary_pct": 12.5,
            "weekly_pct": 44,
        },
    })
    assert snapshot.generated_at == 123
    assert snapshot.claude.primary_pct == 125
    assert snapshot.claude.weekly_pct is None
    assert snapshot.claude.needs_input is True
    assert [(item.model, item.tokens) for item in snapshot.claude.model_usage_today] == [
        ("claude-sonnet", 30),
        ("claude-opus", 12),
    ]
    assert snapshot.codex.primary_pct == 12.5


def test_parse_sanitized_dynamic_fields_and_ignore_invalid_entries():
    snapshot = StatusSnapshot.from_dict({
        "current_sessions": [
            {"id": "session-1", "provider": "claude", "project": "elink-ai",
             "model": "sonnet", "state": "working", "updated_at": 123},
            {"id": "bad", "provider": "unknown"},
        ],
        "recent_events": [
            {"id": "event-1", "provider": "codex", "kind": "needs_input",
             "occurred_at": 124},
            {"id": "bad", "provider": "codex", "kind": "raw_prompt"},
        ],
    })

    assert [(item.id, item.project, item.state) for item in snapshot.current_sessions] == [
        ("session-1", "elink-ai", "working"),
    ]
    assert [(item.id, item.kind) for item in snapshot.recent_events] == [
        ("event-1", "needs_input"),
    ]


def test_dynamic_fields_are_optional_and_limited_to_three_items():
    assert StatusSnapshot.from_dict({}).current_sessions == []
    items = [{"provider": "invalid"}] + [
        {"id": f"s{index}", "provider": "codex", "state": "idle"}
             for index in range(5)]
    parsed = StatusSnapshot.from_dict({"current_sessions": items}).current_sessions
    assert [item.id for item in parsed] == ["s0", "s1", "s2"]


def test_shared_status_fixture_contains_the_dynamic_contract():
    fixture = Path(__file__).parents[2] / "fixtures" / "status-v1.json"
    snapshot = StatusSnapshot.from_dict(json.loads(fixture.read_text()))

    assert snapshot.current_sessions[0].project == "elink-ai"
    assert snapshot.recent_events[0].kind == "needs_input"


def test_percentage_clamps_negative_and_rejects_non_finite_values():
    snapshot = StatusSnapshot.from_dict({
        "claude": {"five_hour_pct": -5, "seven_day_pct": "nan"},
    })

    assert snapshot.claude.primary_pct == 0
    assert snapshot.claude.weekly_pct is None


def test_invalid_status_degrades_to_offline():
    snapshot = StatusSnapshot.from_dict({"claude": {"status": "surprised"}})
    assert snapshot.claude.status == "offline"


def test_invalid_model_usage_degrades_to_empty_list():
    snapshot = StatusSnapshot.from_dict({"claude": {"model_usage_today": None}})
    assert snapshot.claude.model_usage_today == []
