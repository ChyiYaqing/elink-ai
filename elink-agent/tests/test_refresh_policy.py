from elink_agent.models import ProviderStatus, StatusSnapshot
from elink_agent.refresh_policy import RefreshPolicy


def snapshot(*, status="idle", pct=10, needs_input=False):
    return StatusSnapshot(
        claude=ProviderStatus(status=status, primary_pct=pct, needs_input=needs_input),
        codex=ProviderStatus(status="offline"),
    )


def test_first_refresh_is_full_then_unchanged_is_skipped():
    policy = RefreshPolicy(min_interval_s=30, full_every=20)
    value = snapshot()
    decision = policy.decide(value, stale=False, now=100)
    assert decision.refresh and decision.kind == "full"
    policy.record(value, stale=False, kind="full", now=100)
    assert not policy.decide(value, stale=False, now=200).refresh


def test_small_percentage_change_is_throttled_but_status_is_priority():
    policy = RefreshPolicy(min_interval_s=30)
    first = snapshot(pct=10)
    policy.record(first, stale=False, kind="full", now=100)
    assert policy.decide(snapshot(pct=11), stale=False, now=110).reason == "throttled"
    decision = policy.decide(snapshot(status="working", pct=11), stale=False, now=110)
    assert decision.refresh and decision.reason == "priority-change"


def test_periodic_full_refresh_fires_even_when_content_is_unchanged():
    policy = RefreshPolicy(min_interval_s=30, full_interval_s=10)
    value = snapshot()
    policy.record(value, stale=False, kind="full", now=100)
    assert not policy.decide(value, stale=False, now=105).refresh
    decision = policy.decide(value, stale=False, now=111)
    assert decision.refresh and decision.kind == "full" and decision.reason == "maintenance"


def test_reset_minutes_are_grouped_in_five_minute_buckets():
    policy = RefreshPolicy()
    first = snapshot()
    first.claude.primary_reset_min = 29
    policy.record(first, stale=False, kind="full", now=100)
    second = snapshot()
    second.claude.primary_reset_min = 26
    assert not policy.decide(second, stale=False, now=200).refresh
    second.claude.primary_reset_min = 24
    assert policy.decide(second, stale=False, now=200).refresh
