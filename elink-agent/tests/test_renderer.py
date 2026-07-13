from PIL import Image

from elink_agent.models import ProviderStatus, StatusSnapshot
from elink_agent.renderer import DashboardRenderer


def test_renderer_outputs_one_bit_648_by_480():
    snapshot = StatusSnapshot(
        claude=ProviderStatus(status="working", primary_pct=51, weekly_pct=20,
                              primary_reset_min=90, tokens_today=1_250_000),
        codex=ProviderStatus(status="idle", primary_pct=None, weekly_pct=4,
                             needs_input=True),
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
