from __future__ import annotations

import ipaddress
import json
import logging
import threading
import time
from dataclasses import dataclass, field
from datetime import datetime
from pathlib import Path
from typing import Any
from urllib.parse import urlsplit

from . import __version__
from .bridge_client import BridgeClient
from .config import AgentConfig
from .display.base import Display
from .display.frame_diff import FrameDiffer, RefreshPlan
from .models import StatusSnapshot
from .refresh_policy import RefreshPolicy
from .renderer import DashboardRenderer

logger = logging.getLogger(__name__)


def require_private_bridge(bridge_url: str) -> None:
    """远程设置的桥接地址只能指向私有网络。

    公网地址、云厂商元数据地址（169.254.169.254）和任意主机名都拒绝：这个端点
    无鉴权，接受什么就等于把 root 进程的 HTTP 客户端交给谁。配置文件里的地址不走
    这条路——那是本机信任的输入。
    """
    parts = urlsplit(bridge_url)
    if parts.scheme not in {"http", "https"}:
        raise ValueError("bridge_url must be http or https")
    host = parts.hostname
    if not host:
        raise ValueError("bridge_url must name a host")
    if host == "localhost" or host.endswith(".local"):
        return
    try:
        address = ipaddress.ip_address(host)
    except ValueError as error:
        raise ValueError("bridge_url must be a private address") from error
    if not (address.is_private or address.is_loopback):
        raise ValueError("bridge_url must be a private address")
    if address.is_link_local:
        # 169.254.169.254 是云元数据服务；link-local 段整体没有理由成为桥接方
        raise ValueError("bridge_url must not be link-local")


@dataclass(slots=True)
class RuntimeState:
    mode: str = "dashboard"
    last_fetch_at: float = 0.0
    last_refresh_at: float = 0.0
    last_refresh_kind: str = "none"
    # fetch 与 refresh/display 的错误分开保存：fetch 成功不能掩盖仍在重试的刷新故障
    last_error: str | None = None
    refresh_error: str | None = None
    stale: bool = True
    last_refresh_region_count: int = 0
    last_refresh_area: int = 0
    last_refresh_reason: str = "none"
    last_refresh_duration_ms: int = 0
    last_busy_wait_ms: int = 0
    refresh_counts: dict[str, int] = field(default_factory=lambda: {
        "full": 0, "fast-full": 0, "region": 0, "skipped": 0, "failed": 0,
    })
    cumulative_planned_area: int = 0


class AgentService:
    def __init__(self, config: AgentConfig, display: Display):
        self.config = config
        self.display = display
        self.renderer = DashboardRenderer(config.font_path)
        self.client = BridgeClient(config.bridge_url, config.request_timeout_s)
        self.policy = RefreshPolicy(
            min_interval_s=config.min_refresh_interval_s,
            full_every=config.full_refresh_every,
            full_interval_s=config.full_refresh_interval_s,
        )
        self.frame_differ = FrameDiffer(width=display.width, height=display.height)
        self._displayed_frame = None
        self.snapshot = StatusSnapshot.offline()
        self.runtime = RuntimeState()
        self._lock = threading.RLock()
        self._wake = threading.Event()
        self._stop = threading.Event()
        self._thread: threading.Thread | None = None
        self._force: str | None = None
        self._pending_since: float | None = None
        self._request_gen = 0
        self._fetch_failures = 0
        self._next_fetch_at = 0.0
        self._display_retry_at = 0.0
        self._started_at = time.time()
        self._load_state()

    def start(self) -> None:
        if self._thread and self._thread.is_alive():
            return
        self._thread = threading.Thread(target=self._run, name="elink-poller", daemon=True)
        self._thread.start()

    def stop(self) -> None:
        self._stop.set()
        self._wake.set()
        if self._thread:
            self._thread.join(timeout=10)
        self.display.close()

    def request_refresh(self, kind: str = "smart") -> None:
        if kind not in {"smart", "partial", "full"}:
            raise ValueError("refresh must be smart, partial, or full")
        with self._lock:
            self._force = kind
            self._pending_since = 0.0
            self._request_gen += 1
        self._wake.set()

    def set_mode(self, mode: str) -> None:
        if mode not in {"dashboard", "claude", "codex"}:
            raise ValueError("mode must be dashboard, claude, or codex")
        with self._lock:
            if self.runtime.mode != mode:
                self.runtime.mode = mode
                self.policy.last_signature = ""
                self._pending_since = 0.0
                self._request_gen += 1
                self._save_state()
        self._wake.set()

    def set_bridge(self, bridge_url: str) -> None:
        if not bridge_url.startswith(("http://", "https://")):
            bridge_url = "http://" + bridge_url
        # 这个端点没有鉴权，改的又是一个 root 进程反复请求的地址。不限制目标，
        # 局域网上任何人都能把它指向任意主机——那是一个持久化的盲 SSRF 原语。
        # 桥接方只可能在本机或同一个局域网/overlay 上，所以只接受私有地址。
        require_private_bridge(bridge_url)
        with self._lock:
            self.config.bridge_url = bridge_url.rstrip("/")
            self.client = BridgeClient(self.config.bridge_url, self.config.request_timeout_s)
            self.runtime.last_error = None
            self._save_state()
        self._wake.set()

    def device_info(self) -> dict[str, Any]:
        with self._lock:
            now = time.time()
            return {
                "schema_version": 1,
                "device_type": "elink-agent",
                "version": __version__,
                "resolution": [self.display.width, self.display.height],
                "bridge_url": self.config.bridge_url,
                "mode": self.runtime.mode,
                "stale": self.runtime.stale,
                "last_fetch_age_s": None if not self.runtime.last_fetch_at else int(now - self.runtime.last_fetch_at),
                "last_refresh_age_s": None if not self.runtime.last_refresh_at else int(now - self.runtime.last_refresh_at),
                "last_refresh_kind": self.runtime.last_refresh_kind,
                "last_refresh_region_count": self.runtime.last_refresh_region_count,
                "last_refresh_area": self.runtime.last_refresh_area,
                "last_refresh_reason": self.runtime.last_refresh_reason,
                "last_refresh_duration_ms": self.runtime.last_refresh_duration_ms,
                "last_busy_wait_ms": self.runtime.last_busy_wait_ms,
                "refresh_counts": dict(self.runtime.refresh_counts),
                "cumulative_planned_area": self.runtime.cumulative_planned_area,
                "process_uptime_s": int(now - self._started_at),
                "partial_count": self.policy.partial_count,
                "error": self.runtime.refresh_error or self.runtime.last_error,
            }

    def preview_path(self) -> Path:
        return self.config.output_path

    def _run(self) -> None:
        while not self._stop.is_set():
            now_wall = time.time()
            if now_wall >= self._next_fetch_at:
                try:
                    snapshot = self.client.fetch_status()
                    with self._lock:
                        self.snapshot = snapshot
                        self.runtime.last_fetch_at = now_wall
                        self.runtime.last_error = None
                        self._fetch_failures = 0
                        self._next_fetch_at = now_wall + self.config.poll_interval_s
                except Exception as error:
                    logger.warning("bridge fetch failed: %s", error)
                    with self._lock:
                        self.runtime.last_error = str(error)
                        self._fetch_failures += 1
                        backoff = min(60.0, self.config.poll_interval_s * (2 ** min(self._fetch_failures, 5)))
                        self._next_fetch_at = now_wall + backoff

            refresh_kind = None
            with self._lock:
                stale = (not self.runtime.last_fetch_at
                         or now_wall - self.runtime.last_fetch_at >= self.config.stale_after_s)
                self.runtime.stale = stale
                force = self._force
                decision = self.policy.decide(self.snapshot, stale=stale, force=force)
                if decision.refresh:
                    now_mono = time.monotonic()
                    if force or self.config.coalesce_s <= 0:
                        ready = True
                    elif self._pending_since is None:
                        self._pending_since = now_mono
                        ready = False
                    else:
                        ready = now_mono - self._pending_since >= self.config.coalesce_s
                    if ready and now_wall >= self._display_retry_at:
                        refresh_kind = decision.kind
                else:
                    if decision.reason == "unchanged":
                        self._pending_since = None
                        # 自动刷新的新内容失败后，数据若回到屏幕已显示的签名，
                        # 该 display/render 错误已过期，不能永久占据设备状态。
                        if self.runtime.refresh_error and self.runtime.refresh_error.startswith(
                            ("display:", "refresh:")
                        ):
                            self.runtime.refresh_error = None
                            self._display_retry_at = 0.0
            if refresh_kind:
                # 渲染或写预览/状态文件失败不能杀死轮询线程，记错误后按重试窗口再试
                try:
                    self._refresh(refresh_kind, stale)
                except Exception as error:
                    logger.exception("refresh failed")
                    with self._lock:
                        self.runtime.refresh_error = f"refresh: {error}"
                        self._display_retry_at = time.time() + 60

            self._wake.wait(self.config.poll_interval_s)
            self._wake.clear()

    def _refresh(self, kind: str, stale: bool) -> None:
        # 渲染和墨水屏刷新可能阻塞数十秒，不能持锁执行，否则所有 HTTP API 都会被卡住
        with self._lock:
            snapshot = self.snapshot
            mode = self.runtime.mode
            marker = self._request_gen
        image = self.renderer.render(
            snapshot,
            stale=stale,
            mode=mode,
            updated_at=datetime.now().astimezone(),
        )
        if self.config.orientation == 180:
            image = image.rotate(180)
        plan = self._refresh_plan(kind, image)
        if plan.kind == "none":
            with self._lock:
                self.runtime.refresh_counts["skipped"] += 1
                self._finish_refresh(marker)
            logger.info("skipped refresh because the rendered frame is unchanged")
            return
        display_started = time.monotonic()
        try:
            self.display.show(image, kind=plan.kind, regions=plan.regions)
        except Exception as error:
            # 失败时保留 _force/_pending_since，重试窗口到期后同一请求会再次执行
            with self._lock:
                self.runtime.refresh_error = f"display: {error}"
                self.runtime.last_refresh_reason = "display-failed-baseline-unknown"
                self.runtime.last_refresh_duration_ms = int(
                    (time.monotonic() - display_started) * 1000
                )
                self.runtime.last_busy_wait_ms = int(
                    getattr(self.display, "last_busy_wait_s", 0.0) * 1000
                )
                self.runtime.refresh_counts["failed"] += 1
                self._display_retry_at = time.time() + 60
                self._displayed_frame = None
            logger.exception("display refresh failed")
            return
        # 屏幕已经刷新成功；预览/状态文件写失败只记错误，照常 record，
        # 否则签名不更新会导致每个重试周期重复刷屏，磨损墨水屏
        save_error = None
        try:
            self._save_preview(image)
        except Exception as error:
            save_error = f"preview: {error}"
            logger.exception("preview save failed")
        now_wall = time.time()
        with self._lock:
            policy_kind = "full" if plan.kind == "full" else "partial"
            self.policy.record(snapshot, stale=stale, kind=policy_kind)
            self._displayed_frame = image.copy()
            self.runtime.last_refresh_at = now_wall
            self.runtime.last_refresh_kind = plan.kind
            self.runtime.last_refresh_region_count = len(plan.regions)
            self.runtime.last_refresh_area = plan.planned_area
            self.runtime.last_refresh_reason = plan.reason
            self.runtime.last_refresh_duration_ms = int(
                (time.monotonic() - display_started) * 1000
            )
            self.runtime.last_busy_wait_ms = int(
                getattr(self.display, "last_busy_wait_s", 0.0) * 1000
            )
            self.runtime.refresh_counts[plan.kind] += 1
            self.runtime.cumulative_planned_area += plan.planned_area
            self._display_retry_at = 0.0
            self._finish_refresh(marker)
            try:
                self._save_state()
            except Exception as error:
                save_error = save_error or f"state: {error}"
            # 刷新成功：清除上一次的刷新错误（或换成本次非致命的写文件错误）
            self.runtime.refresh_error = save_error
        if save_error:
            logger.warning("refresh succeeded but %s", save_error)
        logger.info("displayed %s refresh", plan.kind)

    def _refresh_plan(self, requested_kind: str, image) -> RefreshPlan:
        screen_area = self.display.width * self.display.height
        if requested_kind == "full":
            return RefreshPlan("full", planned_area=screen_area, reason="requested-full")
        if requested_kind not in {"partial", "smart"}:
            raise ValueError(f"unsupported refresh kind: {requested_kind}")
        return self.frame_differ.plan(self._displayed_frame, image)

    def _finish_refresh(self, marker: int) -> None:
        # 刷新期间到达的 set_mode/request_refresh 不能被清掉，保留其失效标记
        if self._request_gen == marker:
            self._force = None
            self._pending_since = None
        else:
            self.policy.last_signature = ""

    def _save_preview(self, image) -> None:
        path = self.config.output_path
        path.parent.mkdir(parents=True, exist_ok=True)
        temporary = path.with_suffix(path.suffix + ".preview.tmp")
        image.save(temporary, format="PNG")
        temporary.replace(path)

    def _load_state(self) -> None:
        try:
            obj = json.loads(self.config.state_path.read_text())
        except (OSError, ValueError):
            return
        if not isinstance(obj, dict):
            return
        mode = obj.get("mode")
        if mode in {"dashboard", "claude", "codex"}:
            self.runtime.mode = mode
        bridge = obj.get("bridge_url")
        if isinstance(bridge, str) and bridge and not self.config.bridge_url_env_override:
            self.config.bridge_url = bridge.rstrip("/")
            self.client = BridgeClient(self.config.bridge_url, self.config.request_timeout_s)

    def _save_state(self) -> None:
        path = self.config.state_path
        path.parent.mkdir(parents=True, exist_ok=True)
        temporary = path.with_suffix(path.suffix + ".tmp")
        temporary.write_text(json.dumps({
            "mode": self.runtime.mode,
            "bridge_url": self.config.bridge_url,
        }, indent=2) + "\n")
        temporary.replace(path)
