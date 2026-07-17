import json
import tempfile
import threading
from pathlib import Path

from elink_agent.config import AgentConfig
from elink_agent.display.mock import MockDisplay
from elink_agent.models import ProviderStatus, StatusSnapshot
from elink_agent.service import AgentService


class BlockingDisplay(MockDisplay):
    def __init__(self, output_path):
        super().__init__(output_path)
        self.entered = threading.Event()
        self.release = threading.Event()

    def show(self, image, *, kind: str = "full") -> None:
        self.entered.set()
        assert self.release.wait(timeout=10)
        super().show(image, kind=kind)


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


def test_api_state_stays_reachable_while_display_refresh_blocks():
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        config = AgentConfig(output_path=root / "frame.png", state_path=root / "state.json")
        display = BlockingDisplay(config.output_path)
        service = AgentService(config, display)
        worker = threading.Thread(target=service._refresh, args=("full", False))
        worker.start()
        try:
            assert display.entered.wait(timeout=10)
            done = threading.Event()

            def probe():
                service.device_info()
                done.set()

            threading.Thread(target=probe, daemon=True).start()
            assert done.wait(timeout=2), "device_info blocked while the display was refreshing"
        finally:
            display.release.set()
            worker.join(timeout=10)
        assert display.calls == ["full"]


def test_mode_change_during_refresh_is_not_lost():
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        config = AgentConfig(output_path=root / "frame.png", state_path=root / "state.json")
        display = BlockingDisplay(config.output_path)
        service = AgentService(config, display)
        worker = threading.Thread(target=service._refresh, args=("full", False))
        worker.start()
        try:
            assert display.entered.wait(timeout=10)
            service.set_mode("claude")
        finally:
            display.release.set()
            worker.join(timeout=10)
        assert service.runtime.mode == "claude"
        assert service.policy.last_signature == ""


def test_load_state_tolerates_non_object_json():
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        state_path = root / "state.json"
        state_path.write_text("[1, 2, 3]")
        config = AgentConfig(output_path=root / "frame.png", state_path=state_path)
        service = AgentService(config, MockDisplay(config.output_path))
        assert service.runtime.mode == "dashboard"


def test_env_bridge_url_override_wins_over_persisted_state():
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        state_path = root / "state.json"
        state_path.write_text(json.dumps({"bridge_url": "http://persisted:8765"}))
        config = AgentConfig(
            output_path=root / "frame.png",
            state_path=state_path,
            bridge_url="http://environment:8765",
            bridge_url_env_override="http://environment:8765",
        )
        service = AgentService(config, MockDisplay(config.output_path))
        assert service.config.bridge_url == "http://environment:8765"


def test_persisted_bridge_url_applies_without_env_override():
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        state_path = root / "state.json"
        state_path.write_text(json.dumps({"bridge_url": "http://persisted:8765"}))
        config = AgentConfig(output_path=root / "frame.png", state_path=state_path)
        service = AgentService(config, MockDisplay(config.output_path))
        assert service.config.bridge_url == "http://persisted:8765"
