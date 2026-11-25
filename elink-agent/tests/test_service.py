import dataclasses
import json
import socket
import tempfile
import threading
import time
from pathlib import Path

from PIL import Image

from elink_agent.config import AgentConfig
from elink_agent.display.frame_diff import Rect
from elink_agent.display.mock import MockDisplay
from elink_agent.models import ProviderStatus, StatusSnapshot
from elink_agent.renderer import DashboardRenderer
from elink_agent.service import AgentService


class BlockingDisplay(MockDisplay):
    def __init__(self, output_path):
        super().__init__(output_path)
        self.entered = threading.Event()
        self.release = threading.Event()

    def show(self, image, *, kind: str = "full", regions=()) -> None:
        self.entered.set()
        assert self.release.wait(timeout=10)
        super().show(image, kind=kind, regions=regions)


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
    def show(self, image, *, kind: str = "full", regions=()) -> None:
        self.entered.set()
        assert self.release.wait(timeout=10)
        raise RuntimeError("panel hung")


class FrameRenderer:
    def __init__(self, image):
        self.image = image

    def render(self, *_args, **_kwargs):
        return self.image.copy()


class FailOnceDisplay(MockDisplay):
    def __init__(self, output_path):
        super().__init__(output_path)
        self.fail_next = False

    def show(self, image, *, kind: str = "full", regions=()) -> None:
        if self.fail_next:
            self.fail_next = False
            raise RuntimeError("partial transfer failed")
        super().show(image, kind=kind, regions=regions)


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


def test_successful_full_then_small_change_uses_region_refresh():
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        config = AgentConfig(output_path=root / "frame.png", state_path=root / "state.json")
        display = MockDisplay(config.output_path)
        service = AgentService(config, display)
        first = Image.new("1", (648, 480), 255)
        service.renderer = FrameRenderer(first)
        service._refresh("full", False)
        second = first.copy()
        second.putpixel((9, 10), 0)
        service.renderer.image = second
        service._refresh("partial", False)
        assert display.calls == ["full", "region"]
        assert display.region_calls[-1] == (Rect(8, 10, 16, 11),)
        info = service.device_info()
        assert info["last_refresh_kind"] == "region"
        assert info["last_refresh_region_count"] == 1
        assert info["last_refresh_area"] == 8
        assert info["refresh_counts"] == {
            "full": 1, "fast-full": 0, "region": 1, "skipped": 0, "failed": 0,
        }
        assert info["cumulative_planned_area"] == 648 * 480 + 8
        assert info["last_refresh_duration_ms"] >= 0


def test_display_failure_invalidates_baseline_and_next_retry_is_full():
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        config = AgentConfig(output_path=root / "frame.png", state_path=root / "state.json")
        display = FailOnceDisplay(config.output_path)
        service = AgentService(config, display)
        first = Image.new("1", (648, 480), 255)
        service.renderer = FrameRenderer(first)
        service._refresh("full", False)
        changed = first.copy()
        changed.putpixel((9, 10), 0)
        service.renderer.image = changed
        display.fail_next = True
        service._refresh("partial", False)
        assert service._displayed_frame is None
        assert service.runtime.last_refresh_reason == "display-failed-baseline-unknown"
        assert service.runtime.refresh_counts["failed"] == 1
        service._refresh("partial", False)
        assert display.calls == ["full", "full"]
        assert service.runtime.last_refresh_reason == "missing-baseline"


def test_smart_refresh_skips_an_identical_render_and_finishes_request():
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        config = AgentConfig(output_path=root / "frame.png", state_path=root / "state.json")
        display = MockDisplay(config.output_path)
        service = AgentService(config, display)
        service.renderer = FrameRenderer(Image.new("1", (648, 480), 255))
        service._refresh("full", False)
        service.request_refresh("smart")
        service._refresh("smart", False)
        assert display.calls == ["full"]
        assert service._force is None
        assert service.runtime.refresh_counts["skipped"] == 1


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


def test_remote_bridge_url_must_be_private():
    """无鉴权的端点改的是一个 root 进程反复请求的地址：不限目标就是持久化盲 SSRF。"""
    import pytest

    from elink_agent.service import require_private_bridge

    for allowed in [
        "http://192.168.1.50:8765",
        "http://10.1.9.16:8765",
        "http://127.0.0.1:8765",
        "http://elink.local:8765",
    ]:
        require_private_bridge(allowed)

    for rejected in [
        "http://93.184.216.34:8765",          # 公网地址
        "http://169.254.169.254/latest/meta", # 云元数据服务
        "http://attacker.example.com:8765",   # 任意主机名
        "file:///etc/passwd",                 # 非 HTTP scheme
        "http:///v1/status",                  # 没有主机
    ]:
        with pytest.raises(ValueError):
            require_private_bridge(rejected)


def test_bridge_client_refuses_redirects_and_huge_bodies():
    """跟随重定向会让「必须是私有地址」这条检查作废：私有地址回一个 302 就走了。"""
    import http.server
    import json as _json
    import threading

    from elink_agent.bridge_client import MAX_STATUS_BYTES, BridgeClient

    class Handler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            if self.path.startswith("/v1/status"):
                self.send_response(302)
                self.send_header("Location", "http://169.254.169.254/latest/meta-data/")
                self.end_headers()
                return
            self.send_response(404)
            self.end_headers()

        def log_message(self, *args):
            pass

    server = http.server.HTTPServer(("127.0.0.1", 0), Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        client = BridgeClient(f"http://127.0.0.1:{server.server_address[1]}")
        try:
            client.fetch_status()
        except OSError as error:
            assert "302" in str(error)
        else:
            raise AssertionError("重定向必须被拒绝")
    finally:
        server.shutdown()
        server.server_close()

    class Fat(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            body = _json.dumps({"claude": {}, "pad": "x" * (MAX_STATUS_BYTES + 10)}).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, *args):
            pass

    fat = http.server.HTTPServer(("127.0.0.1", 0), Fat)
    fat_thread = threading.Thread(target=fat.serve_forever, daemon=True)
    fat_thread.start()
    try:
        client = BridgeClient(f"http://127.0.0.1:{fat.server_address[1]}")
        try:
            client.fetch_status()
        except OSError as error:
            assert "too large" in str(error)
        else:
            raise AssertionError("超长响应必须被拒绝")
    finally:
        fat.shutdown()
        fat.server_close()


# --- Device-monitor idle switching -------------------------------------------


def _monitor_config(**overrides) -> AgentConfig:
    base = AgentConfig(
        output_path=Path("/tmp/frame.png"),
        state_path=Path("/tmp/state.json"),
        monitor_enabled=True,
        monitor_idle_after_s=5,
        monitor_refresh_interval_s=60,
        coalesce_s=0,
    )
    return dataclasses.replace(base, **overrides)


def _make_service(**overrides):
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        config = _monitor_config(output_path=root / "frame.png",
                                 state_path=root / "state.json", **overrides)
        return AgentService(config, MockDisplay(config.output_path))


def test_target_content_switches_after_idle_threshold():
    service = _make_service(monitor_idle_after_s=10)
    service._last_ai_activity_at = 1000.0
    assert service._target_content(1005) == "ai"
    assert service._target_content(1011) == "monitor"


def test_target_content_always_ai_when_monitor_disabled():
    service = _make_service(monitor_enabled=False)
    service._last_ai_activity_at = 1000.0
    assert service._target_content(2000) == "ai"


def test_ai_active_only_counts_current_work():
    service = _make_service()
    assert not service._ai_active(StatusSnapshot.offline())
    assert service._ai_active(StatusSnapshot(
        claude=ProviderStatus(status="working"), codex=ProviderStatus(status="idle")))
    assert service._ai_active(StatusSnapshot(
        claude=ProviderStatus(status="idle", needs_input=True)))


def test_idle_switch_to_monitor_is_full_refresh():
    service = _make_service(monitor_idle_after_s=5)
    service._last_ai_activity_at = 0.0
    service._displayed_content = "ai"
    service.runtime.last_refresh_at = 0.0
    decision = service._decide_refresh(100.0, False, None)
    assert decision.refresh
    assert decision.kind == "full"
    assert decision.reason == "content-switch"
    assert service._content == "monitor"


def _on_monitor_since(service, shown_at: float, *, working: bool = True, needs_input: bool = False):
    service._last_ai_activity_at = 0.0
    service._displayed_content = "monitor"
    service._monitor_shown_at = shown_at
    service.runtime.last_refresh_at = 0.0
    service.snapshot = StatusSnapshot(
        claude=ProviderStatus(status="working" if working else "idle", needs_input=needs_input),
        codex=ProviderStatus(status="idle"))
    return service


def test_ai_activity_switches_back_from_monitor_to_ai_after_the_dwell():
    service = _make_service(monitor_idle_after_s=5, monitor_min_dwell_s=60)
    _on_monitor_since(service, shown_at=0.0)
    decision = service._decide_refresh(100.0, False, None)
    assert decision.refresh
    assert decision.kind == "full"
    assert decision.reason == "content-switch"
    assert service._content == "ai"
    # 计时被刷新：下一拍不会因为旧的 idle 计时误判回监控页
    assert service._last_ai_activity_at == 100.0


def test_a_brief_ai_blip_does_not_flip_the_panel_off_the_monitor_page():
    """断续干活时的短暂活动不该把面板赶回 AI 页。

    每次来回切换是两次整屏刷新（真机实测每次约 3.6 秒）。真机追踪里三分钟内的
    三次整屏全部来自这种抖动，而不是监控页自己的 tick。
    """
    service = _make_service(monitor_idle_after_s=5, monitor_min_dwell_s=300)
    _on_monitor_since(service, shown_at=0.0)
    decision = service._decide_refresh(100.0, False, None)
    assert service._content == "monitor"
    assert decision.reason != "content-switch"
    # 驻留只是压住切换，AI 的活动计时照常前进
    assert service._last_ai_activity_at == 100.0


def test_needs_input_breaks_the_monitor_dwell_immediately():
    """待审批就是要抢人注意，驻留压不住它。"""
    service = _make_service(monitor_idle_after_s=5, monitor_min_dwell_s=300)
    _on_monitor_since(service, shown_at=0.0, working=False, needs_input=True)
    decision = service._decide_refresh(100.0, False, None)
    assert service._content == "ai"
    assert decision.refresh
    assert decision.reason == "content-switch"


def test_only_providers_the_layout_draws_can_wake_the_screen():
    """待审批和活动只看当前布局画得出来的 provider：dashboard 只画 Claude 和
    Codex，单 provider 模式只画所选那家。叫醒屏幕却看不到是谁在等，等于白刷。"""
    waiting = {name: StatusSnapshot(**{name: ProviderStatus(status="idle", needs_input=True)})
               for name in ("claude", "codex", "gemini")}
    working = {name: StatusSnapshot(**{name: ProviderStatus(status="working")})
               for name in ("claude", "codex", "gemini")}
    visible = {"dashboard": {"claude", "codex"}, "claude": {"claude"},
               "codex": {"codex"}, "gemini": {"gemini"}}
    for mode, shown in visible.items():
        service = _make_service()
        service.runtime.mode = mode
        for name in ("claude", "codex", "gemini"):
            assert service._needs_attention(waiting[name]) == (name in shown), (mode, name)
            assert service._ai_active(waiting[name]) == (name in shown), (mode, name)
            assert service._ai_active(working[name]) == (name in shown), (mode, name)


def test_the_dwell_clock_starts_when_the_monitor_page_reaches_the_panel():
    service = _make_service(monitor_idle_after_s=5, monitor_min_dwell_s=300)
    service._last_ai_activity_at = 0.0
    service._content = "monitor"
    assert service._monitor_shown_at == 0.0
    service._refresh("full", False)
    assert service._displayed_content == "monitor"
    assert service._monitor_shown_at > 0.0


def test_the_loop_wakes_often_enough_to_honour_the_monitor_cadence():
    """循环睡满 poll_interval_s 会让 refresh_interval_s 变成一句空话。

    真机上配 2 秒的监控节拍实际跑成 4.8 秒：面板干活 1.8 秒，剩下 2 秒是刷完之后
    白睡的。取数由 _next_fetch_at 单独把关，所以醒得勤不会多打桥接方一次。
    """
    service = _make_service(poll_interval_s=2.0, monitor_refresh_interval_s=2)
    assert service._loop_tick_s() <= AgentService.LOOP_TICK_S
    assert service._loop_tick_s() < 2.0
    # 取数间隔比循环粒度还小时，不该反过来把循环拖慢
    fast = _make_service(poll_interval_s=0.05)
    assert fast._loop_tick_s() == 0.05


def test_the_loop_lets_the_display_park_itself():
    """会在两次刷新之间保持上电的驱动，靠主循环把面板放回休眠。

    没有这一步，最后一次刷新之后面板会一直停在上电状态——Waveshare 明确说那会让
    它持续处于高压并可能永久损伤，所以这不是优化，是安全要求。
    """
    class ParkingDisplay(MockDisplay):
        def __init__(self, path):
            super().__init__(path)
            self.idle_calls = 0

        def idle(self) -> None:
            self.idle_calls += 1

    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        config = _monitor_config(output_path=root / "frame.png",
                                 state_path=root / "state.json", poll_interval_s=0.05)
        display = ParkingDisplay(config.output_path)
        service = AgentService(config, display)
        service.start()
        try:
            deadline = time.time() + 5
            while display.idle_calls == 0 and time.time() < deadline:
                time.sleep(0.05)
        finally:
            service.stop()
        assert display.idle_calls > 0, "主循环从未给驱动收电源状态的机会"


def test_monitor_ticks_do_not_wait_for_the_coalesce_window():
    """合并窗口是给会抖的页面去抖的，定时采样的页面排这个队只是白等一轮循环。

    真机上这一条值 2 秒：配 2 秒节拍时实际是 5.7 秒一刷，因为第一轮只登记
    pending、第二轮才够合并窗口、然后才是 1.25 秒的刷新。
    """
    service = _make_service(monitor_idle_after_s=5, monitor_refresh_interval_s=2)
    service._last_ai_activity_at = 0.0
    service._displayed_content = "monitor"
    service._monitor_last_refresh_at = 100.0
    decision = service._decide_refresh(103.0, False, None)
    assert decision.refresh
    assert decision.coalesce is False
    # AI 页仍然要过合并窗口：它是数据驱动的，一次突发变化不该刷两遍屏
    service._displayed_content = "ai"
    service._last_ai_activity_at = 103.0
    assert service._decide_refresh(103.0, False, None).coalesce is True


def test_monitor_cadence_is_not_floored_by_the_global_min_interval():
    """监控页是定时采样，节拍该由它自己定。

    min_interval_s 管的是数据驱动页面的抖动（AI 页一有变化就想刷），把监控页的
    采样节奏也压在同一个地板下，就没法在不加快 AI 页的前提下让监控数据动起来。
    """
    service = _make_service(monitor_idle_after_s=5, monitor_refresh_interval_s=2,
                            min_refresh_interval_s=30)
    service._last_ai_activity_at = 0.0
    service._displayed_content = "monitor"
    service._monitor_last_refresh_at = 100.0
    service.runtime.last_refresh_at = 100.0
    decision = service._decide_refresh(103.0, False, None)
    assert decision.refresh, "3 秒后应当已经过了监控页自己的 2 秒节拍"
    assert decision.kind == "partial"


def test_monitor_cadence_never_goes_below_the_panel_cycle():
    """配得再小也没用：面板一次局部刷新要 1.28 秒，更密只会排队。"""
    service = _make_service(monitor_idle_after_s=5, monitor_refresh_interval_s=0.1)
    service._last_ai_activity_at = 0.0
    service._displayed_content = "monitor"
    service._monitor_last_refresh_at = 100.0
    service.runtime.last_refresh_at = 100.0
    assert not service._decide_refresh(100.5, False, None).refresh
    assert service._decide_refresh(100.0 + AgentService.PANEL_MIN_REFRESH_S, False, None).refresh


def test_monitor_tick_is_partial_and_respects_cadence():
    service = _make_service(monitor_idle_after_s=5)
    service._last_ai_activity_at = 0.0
    service._displayed_content = "monitor"
    service.runtime.last_refresh_at = 0.0
    service._monitor_last_refresh_at = 0.0
    first = service._decide_refresh(100.0, False, None)
    assert first.refresh
    assert first.kind == "partial"
    assert first.reason == "monitor-tick"
    # 刚刷过一次，下一拍仍在节奏窗口内 → 节流
    service._monitor_last_refresh_at = 100.0
    assert not service._decide_refresh(100.5, False, None).refresh


def test_display_mode_is_preserved_for_monitor_health():
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        config = _monitor_config(output_path=root / "frame.png",
                                 state_path=root / "state.json")
        display = MockDisplay(config.output_path)
        service = AgentService(config, display)
        service._content = "monitor"
        service._displayed_content = "monitor"
        service._refresh("full", False)
        assert config.output_path.exists()
        assert service._displayed_content == "monitor"
        assert service.runtime.last_refresh_kind == "full"
        assert service._monitor_snapshot is not None
        info = service.device_info()
        assert info["content"] == "monitor"
        assert info["monitor"]["idle"] is True


def test_device_info_reports_the_ip_even_when_the_monitor_page_never_rendered():
    service = _make_service()
    assert service._monitor_snapshot is None
    info = service.device_info()
    assert info["ip_address"] is None or info["ip_address"].count(".") == 3


def test_device_info_reports_a_null_ip_when_there_is_no_route(monkeypatch):
    service = _make_service()

    def fail(*args, **kwargs):
        raise OSError("network is unreachable")

    monkeypatch.setattr(socket, "socket", fail)
    assert service.device_info()["ip_address"] is None


def test_manual_refresh_renders_current_content():
    service = _make_service(monitor_idle_after_s=5)
    service._last_ai_activity_at = 0.0
    service._displayed_content = "monitor"
    service.runtime.last_refresh_at = 0.0
    decision = service._decide_refresh(100.0, False, "full")
    assert decision.refresh
    assert decision.kind == "full"
    assert service._content == "monitor"


def _service_with_baseline(root, display=None):
    config = AgentConfig(
        output_path=root / "frame.png",
        state_path=root / "state.json",
        coalesce_s=0,
    )
    display = display or MockDisplay(config.output_path)
    service = AgentService(config, display)
    service.snapshot = StatusSnapshot(
        claude=ProviderStatus(status="working", primary_pct=25),
        codex=ProviderStatus(status="idle", primary_pct=50),
    )
    service._refresh("full", False)
    return config, display, service


def _toast_is_inked(frame) -> bool:
    """提示条是黑底白字，所以那块区域必然有大量黑像素。"""
    left, top, right, bottom = DashboardRenderer.TOAST_BOX
    crop = frame.convert("1").crop((left, top, right, bottom))
    black = sum(1 for value in crop.getdata() if value == 0)
    return black > crop.width * crop.height * 0.4


def test_toast_uses_region_refresh_and_updates_baseline():
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        _, display, service = _service_with_baseline(root)
        assert not _toast_is_inked(service._displayed_frame)

        service.show_toast("VICTORY")

        assert display.calls == ["full", "region"]
        assert display.region_calls[-1] == (Rect(*DashboardRenderer.TOAST_BOX),)
        # 基线必须跟着变，否则下一次帧差看不出提示条、也就永远擦不掉它
        assert _toast_is_inked(service._displayed_frame)


def test_toast_region_is_byte_aligned():
    """区域刷新按字节打包像素列，x 不对齐会被驱动直接拒绝。"""
    left, _, right, _ = DashboardRenderer.TOAST_BOX
    assert left % 8 == 0
    assert right % 8 == 0
    assert right <= DashboardRenderer.width


def test_toast_without_baseline_is_rejected():
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        config = AgentConfig(output_path=root / "frame.png", state_path=root / "state.json")
        display = MockDisplay(config.output_path)
        service = AgentService(config, display)
        try:
            service.show_toast("HI")
        except RuntimeError:
            pass
        else:
            raise AssertionError("expected a refusal while the baseline is unknown")
        assert display.calls == []


def test_toast_is_erased_by_the_next_refresh():
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        _, display, service = _service_with_baseline(root)
        service.show_toast("CLAUDE")

        # 数据没变，唯一的差异就是屏幕上那条提示，帧差应当把它认成变化区域
        service._refresh("smart", False)

        assert display.calls[-1] in {"region", "fast-full", "full"}
        if display.calls[-1] == "region":
            left, top, right, bottom = DashboardRenderer.TOAST_BOX
            assert any(r.left < right and r.right > left
                       and r.top < bottom and r.bottom > top
                       for r in display.region_calls[-1])
        assert not _toast_is_inked(service._displayed_frame)


def test_toast_does_not_clobber_a_baseline_replaced_mid_refresh():
    """刷提示条不持锁，期间主循环可能刚刷完新内容——那份新基线不能被盖掉。"""
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        config = AgentConfig(
            output_path=root / "frame.png",
            state_path=root / "state.json",
            coalesce_s=0,
        )
        newer = Image.new("1", (648, 480), 1)

        class SwapDisplay(MockDisplay):
            def show(self, image, *, kind="full", regions=()):
                super().show(image, kind=kind, regions=regions)
                if kind == "region":
                    service._displayed_frame = newer

        display = SwapDisplay(config.output_path)
        service = AgentService(config, display)
        service.snapshot = StatusSnapshot(claude=ProviderStatus(status="working"))
        service._refresh("full", False)

        service.show_toast("PALM")

        assert service._displayed_frame is newer
        assert service._toast_until == 0.0
