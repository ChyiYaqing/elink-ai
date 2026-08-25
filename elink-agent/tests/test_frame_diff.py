from PIL import Image, ImageChops, ImageDraw
import pytest

from elink_agent.display.frame_diff import FrameDiffer, Rect


def frame() -> Image.Image:
    return Image.new("1", (648, 480), 255)


def test_missing_or_invalid_baseline_requires_full_refresh():
    differ = FrameDiffer()
    assert differ.plan(None, frame()).kind == "full"
    assert differ.plan(Image.new("1", (8, 8)), frame()).reason == "invalid-baseline"


def test_invalid_current_frame_is_rejected():
    with pytest.raises(ValueError):
        FrameDiffer().plan(frame(), Image.new("1", (8, 8)))


def test_identical_frames_are_skipped():
    value = frame()
    assert FrameDiffer().plan(value, value.copy()).kind == "none"


def test_single_pixel_change_produces_one_byte_aligned_region():
    previous = frame()
    current = previous.copy()
    current.putpixel((9, 10), 0)
    plan = FrameDiffer().plan(previous, current)
    assert plan.kind == "region"
    assert plan.regions == (Rect(8, 10, 16, 11),)
    assert plan.planned_area == 8


def test_neighbouring_changed_tiles_form_one_region():
    previous = frame()
    current = previous.copy()
    draw = ImageDraw.Draw(current)
    draw.rectangle((6, 6, 18, 18), fill=0)
    plan = FrameDiffer().plan(previous, current)
    assert plan.regions == (Rect(0, 6, 24, 19),)


def test_separate_changes_remain_separate_and_sorted():
    previous = frame()
    current = previous.copy()
    current.putpixel((600, 400), 0)
    current.putpixel((8, 16), 0)
    plan = FrameDiffer().plan(previous, current)
    assert plan.regions == (Rect(8, 16, 16, 17), Rect(600, 400, 608, 401))


def test_over_budget_regions_merge_by_least_added_area():
    """超预算时逐对合并代价最小的两块，而不是并成一个外接矩形。

    并成一块等于让相距最远的两处改动决定整块面积——监控页上右上角的时钟和左侧的
    CPU 卡各改几十到几千像素，并起来就是半屏，一次 2.6% 的改动会被判成整屏刷新。
    """
    previous = frame()
    current = previous.copy()
    changed = [(x, 16) for x in (8, 80, 160, 240, 320)]
    for point in changed:
        current.putpixel(point, 0)
    plan = FrameDiffer(max_regions=4).plan(previous, current)
    assert plan.kind == "region"
    assert len(plan.regions) == 4
    assert plan.planned_area < Rect(8, 16, 328, 17).area
    for x, y in changed:
        assert any(r.left <= x < r.right and r.top <= y < r.bottom for r in plan.regions), \
            f"({x}, {y}) fell outside every region"


def test_a_page_that_changed_everywhere_still_collapses_to_one_region():
    """碎片多到 MERGE_LIMIT 以上不再逐对挑：整页都在变，也别在树莓派上跑 O(n³)。"""
    previous = frame()
    current = previous.copy()
    for index in range(FrameDiffer.MERGE_LIMIT + 1):
        current.putpixel((8 + index * 16, 16 + index * 8), 0)
    plan = FrameDiffer(max_regions=4).plan(previous, current)
    assert len(plan.regions) <= 1


def test_large_planned_region_uses_fast_full():
    previous = frame()
    current = previous.copy()
    ImageDraw.Draw(current).rectangle((0, 0, 399, 319), fill=0)
    plan = FrameDiffer(fast_full_threshold=0.35).plan(previous, current)
    assert plan.kind == "fast-full"
    assert plan.reason == "region-area-threshold"
    assert plan.regions == ()


def _six_tall_bars():
    """六根细高条：任意两根并起来都是一个很宽的盒子，硬并到 4 个窗口就要 36% 的屏。"""
    previous = frame()
    current = previous.copy()
    draw = ImageDraw.Draw(current)
    for x in (16, 140, 264, 388, 512, 624):
        draw.rectangle((x, 40, x + 7, 439), fill=0)
    return previous, current


def test_extra_windows_are_preferred_over_repainting_the_whole_screen():
    """并得太狠会把面积撑过阈值，那就多开窗口，而不是整屏重画。

    一个窗口约 350ms BUSY，整屏重画是 4.5s，而且在屏上是看得见的一次全页重绘。
    """
    previous, current = _six_tall_bars()
    differ = FrameDiffer(max_regions=4)
    strict = differ._merge_to_budget(differ._regions(
        ImageChops.difference(previous.convert("L"), current.convert("L"))), 4)
    strict_area = sum(region.area for region in strict)
    assert strict_area / (648 * 480) > differ.fast_full_threshold, "这个场景本该触发整屏"

    plan = differ.plan(previous, current)
    assert plan.kind == "region", "宁可多开窗口也不要整屏重画"
    assert len(plan.regions) > differ.max_regions
    assert len(plan.regions) <= differ.max_windows
    assert plan.planned_area < strict_area
    assert plan.planned_area / (648 * 480) <= differ.fast_full_threshold


def test_a_change_too_large_for_any_window_count_still_falls_back_to_fast_full():
    previous = frame()
    current = previous.copy()
    ImageDraw.Draw(current).rectangle((0, 0, 499, 399), fill=0)
    plan = FrameDiffer().plan(previous, current)
    assert plan.kind == "fast-full"
    assert plan.reason == "region-area-threshold"
