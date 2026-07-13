import tempfile
from pathlib import Path

from elink_agent.config import AgentConfig
from elink_agent.display.mock import MockDisplay
from elink_agent.models import ProviderStatus, StatusSnapshot
from elink_agent.service import AgentService


def test_refresh_writes_preview_and_records_policy():
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        config = AgentConfig(
            output_path=root / "frame.png",
            state_path=root / "state.json",
            coalesce_s=0,
        )
        display = MockDisplay(config.output_path)
        service = AgentService(config, display)
        service.snapshot = StatusSnapshot(
            claude=ProviderStatus(status="working", primary_pct=25),
            codex=ProviderStatus(status="idle", primary_pct=50),
        )
        service._refresh("full", False)
        assert config.output_path.exists()
        assert display.calls == ["full"]
        assert service.policy.last_signature
