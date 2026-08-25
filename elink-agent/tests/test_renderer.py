from dataclasses import replace
from datetime import datetime, timezone
from unittest.mock import Mock

from PIL import Image, ImageDraw

from elink_agent.display.frame_diff import FrameDiffer
from elink_agent.models import (ModelUsage, ProviderStatus, RecentEvent,
                                SessionSummary, StatusSnapshot)
from elink_agent.renderer import DashboardRenderer
from elink_agent.system_monitor import MonitorSnapshot

FIXED_TIME = datetime(2026, 7, 31, 9, 30, tzinfo=timezone.utc)


def _snapshot(**overrides) -> StatusSnapshot:
    base = StatusSnapshot(
        claude=ProviderStatus(status="working", primary_pct=51, weekly_pct=20,
                              primary_reset_min=90, tokens_today=1_250_000,
                              model_usage_today=[ModelUsage("claude-sonnet", 1_000_000),
                                                 ModelUsage("claude-opus", 250_000)]),
        codex=ProviderStatus(status="idle", primary_pct=12, weekly_pct=4,
                             primary_reset_min=140, tokens_today=42_000,
                             model_usage_today=[ModelUsage("gpt-5.6-terra", 42_000)]),
    )
    return replace(base, **overrides)


def _plan(before: StatusSnapshot, after: StatusSnapshot, mode: str = "dashboard"):
    """Diff two frames rendered at the same wall clock, so only data differs."""
    renderer = DashboardRenderer()
    first = renderer.render(before, mode=mode, updated_at=FIXED_TIME)
    second = renderer.render(after, mode=mode, updated_at=FIXED_TIME)
    return renderer, FrameDiffer().plan(first, second)


def _model_row_top(index: int) -> int:
    """Top of the Claude card's model row `index`, mirroring _provider_panel."""
    token_y = DashboardRenderer.CLAUDE_BOX[3] - 108
    return token_y + 34 + index * DashboardRenderer._MODEL_ROW_HEIGHT


def _assert_within(regions, box, renderer: DashboardRenderer) -> None:
    # FrameDiffer 把 X 对齐到字节边界，所以允许左右各扩到最近的 8 的倍数
    left, top, right, bottom = box
    left = left // 8 * 8
    right = min(renderer.width, (right + 7) // 8 * 8)
    assert regions, "expected at least one changed region"
    for region in regions:
        assert region.left >= left and region.right <= right, f"{region} escaped {box} in x"
        assert region.top >= top and region.bottom <= bottom, f"{region} escaped {box} in y"


def test_renderer_outputs_one_bit_648_by_480():
    snapshot = StatusSnapshot(
        claude=ProviderStatus(status="working", primary_pct=51, weekly_pct=20,
                              primary_reset_min=90, tokens_today=1_250_000,
                              model_usage_today=[
                                  ModelUsage("claude-sonnet", 1_000_000),
                                  ModelUsage("claude-opus", 250_000),
                              ]),
        codex=ProviderStatus(status="idle", primary_pct=None, weekly_pct=4,
                             needs_input=True, tokens_today=42_000,
                             model_usage_today=[ModelUsage("gpt-5.6-terra", 42_000)]),
    )
    image = DashboardRenderer().render(snapshot)
    assert image.size == (648, 480)
    assert image.mode == "1"
    extrema = image.convert("L").getextrema()
    assert extrema == (0, 255)


def test_single_provider_mode_renders():
    image = DashboardRenderer().render(StatusSnapshot.offline(), mode="claude", stale=True)
    assert isinstance(image, Image.Image)
    assert image.size == (648, 480)


def test_footer_shows_running_agent_version():
    for mode in ("dashboard", "claude"):
        image = DashboardRenderer().render(StatusSnapshot.offline(), mode=mode)
        footer = image.convert("L").crop((18, 459, 300, 479))
        assert footer.getextrema()[0] == 0, f"version footer missing in {mode} mode"


def test_dual_panel_overage_percentage_fits_before_usage_label():
    renderer = DashboardRenderer()
    draw = ImageDraw.Draw(Image.new("L", (renderer.width, renderer.height), 255))
    percentage = renderer._percentage(102)
    font = renderer._fit_font(draw, percentage, preferred=66, minimum=42,
                              max_width=140, bold=True)

    assert percentage == "102%"
    assert draw.textbbox((0, 0), percentage, font=font)[2] <= 140


def test_overage_percentage_does_not_overfill_progress_bar():
    draw = Mock()

    DashboardRenderer._progress(draw, 10, 5, 110, 102)

    assert draw.rectangle.call_args_list[0].args == ((10, 5, 110, 23),)
    assert draw.rectangle.call_args_list[1].args == ((13, 8, 107, 20),)


def test_model_labels_drop_redundant_provider_prefix():
    assert DashboardRenderer._model_label("claude-sonnet-4", "Claude") == "sonnet-4"
    assert DashboardRenderer._model_label("gpt-5.6-terra", "Codex") == "5.6-terra"


def test_top_level_components_do_not_overlap():
    renderer = DashboardRenderer()
    for mode in ("dashboard", "claude"):
        boxes = [box for name, box in renderer.component_boxes(mode).items()
                 if "." not in name]
        for index, first in enumerate(boxes):
            for second in boxes[index + 1:]:
                overlaps = (first[0] < second[2] and second[0] < first[2]
                            and first[1] < second[3] and second[1] < first[3])
                assert not overlaps, f"{first} overlaps {second} in {mode} mode"


def test_attention_change_stays_inside_the_status_badge():
    before = _snapshot()
    after = replace(before, claude=replace(before.claude, needs_input=True))

    renderer, plan = _plan(before, after)

    # 加粗边框曾让这个变化越过面积阈值，退化成整帧刷新
    assert plan.kind == "region"
    _assert_within(plan.regions, renderer.component_boxes()["claude.badge"], renderer)


def test_error_change_stays_inside_the_status_badge():
    before = _snapshot()
    after = replace(before, codex=replace(before.codex, error="bridge failed"))

    renderer, plan = _plan(before, after)

    assert plan.kind == "region"
    _assert_within(plan.regions, renderer.component_boxes()["codex.badge"], renderer)


def test_one_provider_change_leaves_the_other_card_untouched():
    before = _snapshot()
    after = replace(before, codex=replace(before.codex, tokens_today=99_000,
                                          model_usage_today=[ModelUsage("gpt-5.6-terra", 99_000)]))

    renderer, plan = _plan(before, after)

    assert plan.kind == "region"
    _assert_within(plan.regions, renderer.component_boxes()["codex"], renderer)


def test_extra_model_row_does_not_reflow_the_rows_above_it():
    before = _snapshot()
    after = replace(before, claude=replace(
        before.claude,
        model_usage_today=[*before.claude.model_usage_today, ModelUsage("claude-haiku", 10_000)],
    ))

    renderer, plan = _plan(before, after)

    assert plan.kind == "region"
    _assert_within(plan.regions, renderer.component_boxes()["claude"], renderer)
    # 前两行位于第三行之上，重排会把脏矩形顶到它们的 y 范围里
    assert min(region.top for region in plan.regions) >= _model_row_top(2)


def test_model_rows_beyond_the_fixed_count_are_reported_not_dropped():
    usage = [ModelUsage(f"claude-m{index}", 1000 - index) for index in range(7)]
    snapshot = _snapshot(claude=ProviderStatus(status="idle", model_usage_today=usage))

    image = DashboardRenderer().render(snapshot, updated_at=FIXED_TIME).convert("L")

    overflow_row = _model_row_top(DashboardRenderer._MODEL_ROWS - 1)
    band = image.crop((34, overflow_row, 300, overflow_row + DashboardRenderer._MODEL_ROW_HEIGHT))
    assert band.getextrema()[0] == 0, "the hidden-model count should render, not vanish"


def test_session_change_stays_inside_its_reserved_row():
    before = _snapshot()
    after = replace(before, current_sessions=[
        SessionSummary("s1", "claude", "elink-ai", "sonnet", "working", 1_783_933_140),
    ])

    renderer, plan = _plan(before, after)

    assert plan.kind == "region"
    boxes = renderer.component_boxes()
    allowed = (boxes["claude"][0], boxes["claude.session"][1],
               boxes["claude"][2], boxes["claude.session"][3])
    _assert_within(plan.regions, allowed, renderer)


def test_recent_event_change_stays_inside_its_reserved_row():
    session = SessionSummary("s1", "codex", "elink-ai", "5.6", "idle", 1_783_933_140)
    before = replace(_snapshot(), current_sessions=[session])
    after = replace(before, recent_events=[
        RecentEvent("e1", "codex", "needs_input", 1_783_933_180),
    ])

    renderer, plan = _plan(before, after)

    assert plan.kind == "region"
    _assert_within(plan.regions, renderer.component_boxes()["codex.event"], renderer)


class TestStaleBadge:
    """限流导致的取数失败不该画成 ERROR —— 那会让人以为数字不能信。"""

    def _badge_text(self, provider: ProviderStatus) -> str:
        renderer = DashboardRenderer()
        image = Image.new("1", (renderer.width, renderer.height), 255)
        draw = ImageDraw.Draw(image)
        captured = []
        original = draw.text
        draw.text = lambda xy, text, **kw: captured.append(text) or original(xy, text, **kw)
        renderer._status_badge(draw, (40, 170, 390, 620), provider, False)
        return captured[0]

    def _cached(self, **overrides) -> ProviderStatus:
        base = ProviderStatus(status="working", primary_pct=33, weekly_pct=38,
                              error="Claude usage HTTP 429", usage_cached=True)
        return replace(base, **overrides)

    def test_rate_limited_with_cached_values_shows_stale(self):
        assert self._badge_text(self._cached()) == "STALE"

    def test_error_without_usable_values_still_shows_error(self):
        assert self._badge_text(
            self._cached(usage_cached=False, primary_pct=None, weekly_pct=None)) == "ERROR"

    def test_needs_input_outranks_stale(self):
        assert self._badge_text(self._cached(needs_input=True)) == "ACTION REQUIRED"

    def test_healthy_provider_shows_status(self):
        assert self._badge_text(self._cached(error=None)) == "WORKING"

    def test_stale_is_not_inverted(self):
        """反白留给要人处理的事；STALE 与 WORKING 同一视觉层级。"""
        renderer = DashboardRenderer()
        box = (40, 170, 390, 620)
        bx0, by0, bx1, by1 = renderer._badge_box(box, False)

        def filled(provider) -> bool:
            image = Image.new("1", (renderer.width, renderer.height), 255)
            renderer._status_badge(ImageDraw.Draw(image), box, provider, False)
            return image.getpixel((bx0 + 2, by0 + 2)) == 0

        assert filled(self._cached()) is False
        assert filled(self._cached(usage_cached=False, primary_pct=None, weekly_pct=None)) is True


def _monitor(**overrides) -> MonitorSnapshot:
    base = MonitorSnapshot(
        ts=1_783_933_000.0, load_1m=1.0, load_5m=0.8, load_15m=0.5,
        cpu_percent=None, mem_total_kb=1_000_000, mem_available_kb=600_000,
        mem_percent=40.0, disk_total=60 * 1024 ** 3, disk_used=12 * 1024 ** 3,
        disk_percent=20.0, temp_c=47.0, uptime_s=90000.0,
        net_rx_bps=1_000_000, net_tx_bps=500_000,
        net_rx_total=1_000_000_000, net_tx_total=500_000_000, hostname="3BP",
        ip_address="192.168.31.42",
    )
    return replace(base, **overrides)


def test_render_monitor_is_one_bit_648_by_480():
    image = DashboardRenderer().render_monitor(_monitor(), updated_at=FIXED_TIME, panel={})
    assert image.size == (648, 480)
    assert image.mode == "1"
    assert image.convert("L").getextrema() == (0, 255)


def test_monitor_cards_render_text_in_each_card():
    image = DashboardRenderer().render_monitor(
        _monitor(), updated_at=FIXED_TIME, panel={"last_refresh_kind": "region"}).convert("L")
    for box in DashboardRenderer()._monitor_boxes():
        x0, y0, x1, y1 = box
        assert image.crop((x0, y0, x1, y1)).getextrema()[0] == 0, f"card {box} is blank"


def test_monitor_boxes_do_not_overlap_and_stay_in_bounds():
    renderer = DashboardRenderer()
    boxes = renderer._monitor_boxes()
    assert len(boxes) == 6
    for box in boxes:
        x0, y0, x1, y1 = box
        assert x0 >= 0 and x1 <= renderer.width
        assert y0 >= 0 and y1 <= renderer.height
    for index, first in enumerate(boxes):
        for second in boxes[index + 1:]:
            overlaps = (first[0] < second[2] and second[0] < first[2]
                        and first[1] < second[3] and second[1] < first[3])
            assert not overlaps, f"{first} overlaps {second}"


def test_monitor_single_card_change_stays_inside_its_card():
    renderer = DashboardRenderer()
    cpu_box = renderer._monitor_boxes()[0]
    before = renderer.render_monitor(_monitor(load_1m=1.0), updated_at=FIXED_TIME, panel={})
    after = renderer.render_monitor(_monitor(load_1m=3.0), updated_at=FIXED_TIME, panel={})
    plan = FrameDiffer().plan(before, after)
    assert plan.kind == "region"
    _assert_within(plan.regions, cpu_box, renderer)


def test_monitor_panel_card_reflects_refresh_error():
    renderer = DashboardRenderer()
    panel = {"last_refresh_kind": "full", "error": "display: SPI error",
             "last_busy_wait_ms": 420}
    assert renderer._panel_value(panel) == "ERROR"
    image = renderer.render_monitor(_monitor(), updated_at=FIXED_TIME, panel=panel)
    assert image.size == (648, 480)


def test_fonts_are_cached_per_size_and_weight():
    renderer = DashboardRenderer()
    assert renderer._font(20, bold=True) is renderer._font(20, bold=True)
    assert renderer._font(20, bold=True) is not renderer._font(20, bold=False)
    assert renderer._font(20, bold=True) is not renderer._font(21, bold=True)


def test_monitor_row_change_stays_inside_its_row():
    renderer = DashboardRenderer()
    mem_box = renderer._monitor_boxes()[1]
    before = renderer.render_monitor(_monitor(mem_percent=40.0), updated_at=FIXED_TIME, panel={})
    after = renderer.render_monitor(_monitor(mem_percent=70.0), updated_at=FIXED_TIME, panel={})
    plan = FrameDiffer().plan(before, after)
    assert plan.kind == "region"
    _assert_within(plan.regions, mem_box, renderer)


def test_monitor_sparkline_change_stays_inside_the_hero_card():
    renderer = DashboardRenderer()
    hero_box = renderer._monitor_boxes()[0]
    history = tuple(float(value) for value in range(0, 60, 3))
    before = renderer.render_monitor(_monitor(cpu_history=history), updated_at=FIXED_TIME, panel={})
    after = renderer.render_monitor(_monitor(cpu_history=history + (95.0,)),
                                    updated_at=FIXED_TIME, panel={})
    plan = FrameDiffer().plan(before, after)
    assert plan.kind == "region"
    _assert_within(plan.regions, hero_box, renderer)


def test_monitor_sparkline_only_draws_the_newest_samples():
    renderer = DashboardRenderer()
    slots = DashboardRenderer.MONITOR_SPARK_SLOTS
    long_history = tuple(float(value % 100) for value in range(slots * 2))
    full = renderer.render_monitor(_monitor(cpu_history=long_history),
                                   updated_at=FIXED_TIME, panel={})
    tail = renderer.render_monitor(_monitor(cpu_history=long_history[-slots:]),
                                   updated_at=FIXED_TIME, panel={})
    assert full.tobytes() == tail.tobytes()


def test_monitor_sparkline_without_history_still_renders():
    renderer = DashboardRenderer()
    image = renderer.render_monitor(_monitor(cpu_history=()), updated_at=FIXED_TIME, panel={})
    hero = renderer._monitor_boxes()[0]
    assert image.convert("L").crop(hero).getextrema()[0] == 0


def test_rate_formatting_keeps_three_significant_digits():
    assert DashboardRenderer._fmt_rate(1_200_000) == "1.2M/s"
    assert DashboardRenderer._fmt_rate(440_000) == "440K/s"
    assert DashboardRenderer._fmt_rate(1_500) == "1.5K/s"
    assert DashboardRenderer._fmt_rate(999) == "999B/s"
    assert DashboardRenderer._fmt_rate(None) == "—"


def test_monitor_strip_shows_the_ip_next_to_the_hostname():
    renderer = DashboardRenderer()
    assert renderer._identity(_monitor()) == "3BP · 192.168.31.42"
    assert renderer._identity(_monitor(ip_address=None)) == "3BP"
    strip = renderer._monitor_boxes()[5]
    with_ip = renderer.render_monitor(_monitor(), updated_at=FIXED_TIME, panel={}).convert("L")
    without = renderer.render_monitor(_monitor(ip_address=None),
                                      updated_at=FIXED_TIME, panel={}).convert("L")
    assert with_ip.crop(strip).tobytes() != without.crop(strip).tobytes()


def test_monitor_identity_never_runs_into_the_panel_state():
    """主机名再长也只能占右边的空档，不能盖住左边的面板状态。"""
    renderer = DashboardRenderer()
    x0, y0, x1, y1 = renderer._monitor_boxes()[5]
    panel = {"last_refresh_kind": "region"}
    short = renderer.render_monitor(_monitor(), updated_at=FIXED_TIME, panel=panel).convert("L")
    long = renderer.render_monitor(
        _monitor(hostname="raspberrypi-workshop-3b-plus-north-lab-rack-07",
                 ip_address="192.168.31.240"),
        updated_at=FIXED_TIME, panel=panel).convert("L")
    state = (x0, y0, x0 + 160, y1)
    assert short.crop(state).tobytes() == long.crop(state).tobytes()


def test_monitor_separators_stay_out_of_every_card():
    """分隔线必须落在框与框的缝里，否则会被算进某张卡的脏矩形。"""
    renderer = DashboardRenderer()
    blank = Image.new("L", (renderer.width, renderer.height), 255)
    renderer._monitor_rules(ImageDraw.Draw(blank))
    assert blank.getextrema()[0] == 0, "expected the rules to draw something"
    for box in renderer._monitor_boxes():
        assert blank.crop(box).getextrema() == (255, 255), f"a rule crosses {box}"


def test_monitor_sparkline_scales_to_the_peak_so_idle_load_stays_visible():
    """闲置机器长期在个位数百分比：固定 0-100 会把趋势压没（真机验证发现）。"""
    renderer = DashboardRenderer()
    hero = renderer._monitor_boxes()[0]
    idle = renderer.render_monitor(_monitor(cpu_history=(2.0, 3.0, 2.0, 6.0)),
                                   updated_at=FIXED_TIME, panel={}).convert("L")
    flat = renderer.render_monitor(_monitor(cpu_history=(2.0, 2.0, 2.0, 2.0)),
                                   updated_at=FIXED_TIME, panel={}).convert("L")
    band = (hero[0], hero[1] + 208, hero[2], hero[1] + 286)
    assert idle.crop(band).getextrema()[0] == 0, "idle history drew nothing"
    assert idle.crop(band).tobytes() != flat.crop(band).tobytes()
