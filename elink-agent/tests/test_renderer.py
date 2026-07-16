from unittest.mock import Mock

from PIL import Image, ImageDraw

from elink_agent.models import ModelUsage, ProviderStatus, StatusSnapshot
from elink_agent.renderer import DashboardRenderer


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
