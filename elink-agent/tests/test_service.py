import json
import tempfile
import threading
import time
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


class FailingBlockingDisplay(BlockingDisplay):
    def show(self, image, *, kind: str = "full") -> None:
        self.entered.set()
        assert self.release.wait(timeout=10)
        raise RuntimeError("panel hung")


def test_identical_refresh_request_during_failed_refresh_is_preserved():
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        config = AgentConfig(output_path=root / "frame.png", state_path=root / "state.json")
        display = FailingBlockingDisplay(config.output_path)
        service = AgentService(config, display)
        service.request_refresh("full")
        worker = threading.Thread(target=service._refresh, args=("full", False))
        worker.start()
        try:
            assert display.entered.wait(timeout=10)
            service.request_refresh("full")
        finally:
            display.release.set()
            worker.join(timeout=10)
        assert service._force == "full"
        assert service.policy.last_signature == ""


def test_forced_refresh_survives_display_failure():
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        config = AgentConfig(output_path=root / "frame.png", state_path=root / "state.json")
        display = FailingBlockingDisplay(config.output_path)
        display.release.set()
        service = AgentService(config, display)
        service.request_refresh("full")
        service._refresh("full", False)
        assert service._force == "full"
        assert service._display_retry_at > 0


class StubClient:
    def fetch_status(self):
        return StatusSnapshot(
            claude=ProviderStatus(status="idle"),
            codex=ProviderStatus(status="idle"),
        )


class RevertingClient:
    def __init__(self, changed, original):
        self.changed = changed
        self.original = original
        self.calls = 0

    def fetch_status(self):
        self.calls += 1
        return self.changed if self.calls == 1 else self.original


def test_obsolete_display_error_clears_when_content_reverts_to_displayed_state():
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        config = AgentConfig(
            output_path=root / "frame.png",
            state_path=root / "state.json",
            coalesce_s=0,
            poll_interval_s=0.02,
        )
        display = FailingBlockingDisplay(config.output_path)
        display.release.set()
        service = AgentService(config, display)
        original = StatusSnapshot(
            claude=ProviderStatus(status="idle", primary_pct=10),
            codex=ProviderStatus(status="idle"),
        )
        changed = StatusSnapshot(
            claude=ProviderStatus(status="working", primary_pct=20),
            codex=ProviderStatus(status="idle"),
        )
        service.policy.record(original, stale=False, kind="full")
        service.snapshot = original
        service.runtime.last_fetch_at = time.time()
        client = RevertingClient(changed, original)
        service.client = client

        worker = threading.Thread(target=service._run, daemon=True)
        worker.start()
        deadline = time.time() + 5
        saw_error = False
        while time.time() < deadline:
            if service.runtime.refresh_error:
                saw_error = True
            if saw_error and client.calls >= 2 and service.runtime.refresh_error is None:
                break
            time.sleep(0.01)
        service._stop.set()
        service._wake.set()
        worker.join(timeout=5)

        assert saw_error
        assert client.calls >= 2
        assert service.runtime.refresh_error is None


def test_preview_write_failure_completes_refresh_without_killing_loop():
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        # output_path 指向已存在目录，_save_preview 的 replace 必然失败
        output_dir = root / "frame.png"
        output_dir.mkdir()
        config = AgentConfig(
            output_path=output_dir,
            state_path=root / "state.json",
            coalesce_s=0,
            poll_interval_s=0.05,
        )
        display = MockDisplay(root / "other.png")
        service = AgentService(config, display)
        service.client = StubClient()
        service.request_refresh("full")
        worker = threading.Thread(target=service._run, daemon=True)
        worker.start()
        deadline = time.time() + 5
        while time.time() < deadline:
            if display.calls and service._force is None:
                break
            time.sleep(0.02)
        assert worker.is_alive(), "poller loop died on preview write failure"
        service._stop.set()
        service._wake.set()
        worker.join(timeout=5)
        assert not worker.is_alive(), "poller loop failed to stop"
        # 屏幕已刷新且请求已完成：不能因预览写失败而每 60 秒重复刷屏
        assert display.calls == ["full"]
        assert service._force is None
        assert service.policy.last_signature


def test_render_failure_keeps_poller_alive_and_preserves_force():
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        config = AgentConfig(
            output_path=root / "frame.png",
            state_path=root / "state.json",
            coalesce_s=0,
            poll_interval_s=0.05,
        )
        service = AgentService(config, MockDisplay(config.output_path))
        service.client = StubClient()
        service.renderer = None  # render 阶段必然抛 AttributeError
        service.request_refresh("full")
        worker = threading.Thread(target=service._run, daemon=True)
        worker.start()
        deadline = time.time() + 5
        while time.time() < deadline:
            error = service.runtime.refresh_error
            if error and error.startswith("refresh:"):
                break
            time.sleep(0.02)
        assert worker.is_alive(), "poller loop died on render failure"
        service._stop.set()
        service._wake.set()
        worker.join(timeout=5)
        # fetch 成功不能掩盖仍在重试的刷新故障：refresh_error 独立于 last_error
        assert service.runtime.refresh_error
        assert service.runtime.refresh_error.startswith("refresh:")
        assert service.device_info()["error"].startswith("refresh:")
        assert service._force == "full"


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
