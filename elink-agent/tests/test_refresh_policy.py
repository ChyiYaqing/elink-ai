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


def test_manual_smart_refresh_is_deferred_to_frame_differ():
    decision = RefreshPolicy().decide(snapshot(), stale=False, now=100, force="smart")
    assert decision.refresh and decision.kind == "smart" and decision.reason == "manual"


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


def test_full_every_one_disables_partial_refresh():
    policy = RefreshPolicy(min_interval_s=0, full_every=1)
    policy.record(snapshot(pct=10), stale=False, kind="full", now=100)
    decision = policy.decide(snapshot(pct=50), stale=False, now=200)
    assert decision.refresh and decision.kind == "full"


def test_full_every_one_does_not_loop_on_unchanged_content():
    policy = RefreshPolicy(min_interval_s=0, full_every=1, full_interval_s=21600)
    value = snapshot(pct=10)
    policy.record(value, stale=False, kind="full", now=100)
    # full 后计数归零，相同内容不能被误判为维护性全刷（否则每个轮询都全刷）
    assert not policy.decide(value, stale=False, now=102).refresh
    assert not policy.decide(value, stale=False, now=104).refresh


def test_full_every_counts_the_full_refresh_itself():
    policy = RefreshPolicy(min_interval_s=0, full_every=2)
    policy.record(snapshot(pct=10), stale=False, kind="full", now=100)
    first = policy.decide(snapshot(pct=50), stale=False, now=200)
    assert first.refresh and first.kind == "partial"
    policy.record(snapshot(pct=50), stale=False, kind="partial", now=200)
    second = policy.decide(snapshot(pct=90), stale=False, now=300)
    assert second.refresh and second.kind == "full"


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


def test_manual_refresh_still_obeys_the_minimum_interval():
    """刷新端点没有鉴权。绕过最小间隔就意味着局域网上任何人都能不停驱动墨水屏。"""
    policy = RefreshPolicy(min_interval_s=30, full_every=20)
    value = snapshot()
    first = policy.decide(value, stale=False, now=100, force="full")
    assert first.refresh and first.reason == "manual"
    policy.record(value, stale=False, kind="full", now=100)

    throttled = policy.decide(value, stale=False, now=110, force="full")
    assert not throttled.refresh and throttled.reason == "throttled"

    # 请求不会被丢掉：调用方保留 force，窗口一到同一个请求就执行
    later = policy.decide(value, stale=False, now=131, force="full")
    assert later.refresh and later.kind == "full"
