from elink_agent.models import StatusSnapshot


def test_parse_bridge_shape_and_clamp_percentage():
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
    assert snapshot.claude.primary_pct == 100
    assert snapshot.claude.weekly_pct is None
    assert snapshot.claude.needs_input is True
    assert [(item.model, item.tokens) for item in snapshot.claude.model_usage_today] == [
        ("claude-sonnet", 30),
        ("claude-opus", 12),
    ]
    assert snapshot.codex.primary_pct == 12.5


def test_invalid_status_degrades_to_offline():
    snapshot = StatusSnapshot.from_dict({"claude": {"status": "surprised"}})
    assert snapshot.claude.status == "offline"


def test_invalid_model_usage_degrades_to_empty_list():
    snapshot = StatusSnapshot.from_dict({"claude": {"model_usage_today": None}})
    assert snapshot.claude.model_usage_today == []
