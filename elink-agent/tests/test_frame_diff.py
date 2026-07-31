from PIL import Image, ImageDraw
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


def test_too_many_regions_collapse_to_one_outer_region():
    previous = frame()
    current = previous.copy()
    for x in (8, 80, 160, 240, 320):
        current.putpixel((x, 16), 0)
    plan = FrameDiffer(max_regions=4).plan(previous, current)
    assert plan.kind == "region"
    assert plan.regions == (Rect(8, 16, 328, 17),)


def test_large_planned_region_uses_fast_full():
    previous = frame()
    current = previous.copy()
    ImageDraw.Draw(current).rectangle((0, 0, 399, 319), fill=0)
    plan = FrameDiffer(fast_full_threshold=0.35).plan(previous, current)
    assert plan.kind == "fast-full"
    assert plan.reason == "region-area-threshold"
    assert plan.regions == ()
