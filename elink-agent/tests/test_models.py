import json
from pathlib import Path

from elink_agent.models import ProviderStatus, StatusSnapshot


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


class TestProviderUsageStale:
    """额度取数失败但仍有可信缓存时，属于陈旧而非错误。"""

    def _status(self, **overrides):
        obj = {
            "status": "working",
            "five_hour_pct": 33,
            "seven_day_pct": 38,
            "error": "Claude usage HTTP 429",
            "provider_usage_cached": True,
        }
        obj.update(overrides)
        return ProviderStatus.from_dict(obj, provider="claude")

    def test_parses_usage_cached(self):
        assert self._status().usage_cached is True
        assert self._status(provider_usage_cached=False).usage_cached is False

    def test_omitted_field_defaults_false(self):
        status = ProviderStatus.from_dict({"status": "idle"}, provider="claude")
        assert status.usage_cached is False
        assert status.usage_is_stale is False

    def test_cached_values_with_error_are_stale(self):
        assert self._status().usage_is_stale is True

    def test_error_without_cache_is_not_stale(self):
        assert self._status(provider_usage_cached=False).usage_is_stale is False

    def test_cache_without_any_percentage_is_not_stale(self):
        status = self._status(five_hour_pct=None, seven_day_pct=None)
        assert status.usage_is_stale is False

    def test_no_error_is_never_stale(self):
        assert self._status(error=None).usage_is_stale is False


class TestExtraUsageAndScopedLimits:
    """额外用量与模型作用域周限额跨桥的解析。"""

    def _status(self, **overrides):
        obj = {"status": "working", "five_hour_pct": 9}
        obj.update(overrides)
        return ProviderStatus.from_dict(obj, provider="claude")

    def test_parses_extra_usage_in_major_units(self):
        status = self._status(extra_usage={
            "used": 10.3, "limit": 100.0, "pct": 10.3, "unit": "usd",
        })
        assert status.extra_usage is not None
        assert status.extra_usage.used == 10.3
        assert status.extra_usage.limit == 100.0
        assert status.extra_usage.pct == 10.3
        assert status.extra_usage.unit == "USD"
        assert status.extra_usage.is_credits is False

    def test_derives_percentage_and_defaults_unit(self):
        status = self._status(extra_usage={"used": 25.0, "limit": 100.0})
        assert status.extra_usage.pct == 25.0
        assert status.extra_usage.unit == "USD"

    def test_codex_limits_are_counted_in_credits_not_currency(self):
        status = self._status(extra_usage={
            "used": 250.0, "limit": 1000.0, "pct": 25.0, "unit": "credits",
        })
        assert status.extra_usage.is_credits is True
        assert status.extra_usage.unit == "credits"

    def test_credit_balance_is_none_when_the_account_has_no_pool(self):
        assert self._status().credit_balance is None
        assert self._status(credit_balance=1250.5).credit_balance == 1250.5
        assert self._status(credit_balance="lots").credit_balance is None

    def test_missing_or_unusable_pool_is_none(self):
        # 老 bridge 不发这个字段；上限为零则整块不成立
        assert self._status().extra_usage is None
        assert self._status(extra_usage=None).extra_usage is None
        assert self._status(extra_usage={"used": 0, "limit": 0}).extra_usage is None
        assert self._status(extra_usage={"used": 1}).extra_usage is None
        assert self._status(extra_usage="10 dollars").extra_usage is None

    def test_parses_scoped_limits(self):
        status = self._status(scoped_limits=[
            {"id": "claude-opus-5", "title": "Opus", "pct": 61, "reset_min": 180},
            # 没有标题的条目在屏幕上无从指代，丢掉
            {"id": "mystery", "pct": 4},
        ])
        assert [limit.title for limit in status.scoped_limits] == ["Opus"]
        assert status.scoped_limits[0].id == "claude-opus-5"
        assert status.scoped_limits[0].pct == 61
        assert status.scoped_limits[0].reset_min == 180

    def test_missing_scoped_limits_default_empty(self):
        assert self._status().scoped_limits == []
        assert self._status(scoped_limits="opus").scoped_limits == []
