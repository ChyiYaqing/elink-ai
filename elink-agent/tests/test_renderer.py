from dataclasses import replace
from datetime import datetime, timezone
from unittest.mock import Mock

from PIL import Image, ImageDraw

from elink_agent.display.frame_diff import FrameDiffer
from elink_agent.models import (ModelUsage, ProviderStatus, RecentEvent,
                                SessionSummary, StatusSnapshot)
from elink_agent.renderer import DashboardRenderer

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
