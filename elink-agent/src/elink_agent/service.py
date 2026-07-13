from __future__ import annotations

import json
import logging
import threading
import time
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from typing import Any

from .bridge_client import BridgeClient
from .config import AgentConfig
from .display.base import Display
from .models import StatusSnapshot
from .refresh_policy import RefreshPolicy
from .renderer import DashboardRenderer

logger = logging.getLogger(__name__)


@dataclass(slots=True)
class RuntimeState:
    mode: str = "dashboard"
    last_fetch_at: float = 0.0
    last_refresh_at: float = 0.0
    last_refresh_kind: str = "none"
    last_error: str | None = None
    stale: bool = True


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
        self.snapshot = StatusSnapshot.offline()
        self.runtime = RuntimeState()
        self._lock = threading.RLock()
        self._wake = threading.Event()
        self._stop = threading.Event()
        self._thread: threading.Thread | None = None
        self._force: str | None = None
        self._pending_since: float | None = None
        self._fetch_failures = 0
        self._next_fetch_at = 0.0
        self._display_retry_at = 0.0
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
            self._force = None if kind == "smart" else kind
            if kind == "smart":
                self.policy.last_signature = ""
            self._pending_since = 0.0
        self._wake.set()

    def set_mode(self, mode: str) -> None:
        if mode not in {"dashboard", "claude", "codex"}:
            raise ValueError("mode must be dashboard, claude, or codex")
        with self._lock:
            if self.runtime.mode != mode:
                self.runtime.mode = mode
                self.policy.last_signature = ""
                self._pending_since = 0.0
                self._save_state()
        self._wake.set()

    def set_bridge(self, bridge_url: str) -> None:
        if not bridge_url.startswith(("http://", "https://")):
            bridge_url = "http://" + bridge_url
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
                "version": "0.1.0",
                "resolution": [self.display.width, self.display.height],
                "bridge_url": self.config.bridge_url,
                "mode": self.runtime.mode,
                "stale": self.runtime.stale,
                "last_fetch_age_s": None if not self.runtime.last_fetch_at else int(now - self.runtime.last_fetch_at),
                "last_refresh_age_s": None if not self.runtime.last_refresh_at else int(now - self.runtime.last_refresh_at),
                "last_refresh_kind": self.runtime.last_refresh_kind,
                "partial_count": self.policy.partial_count,
                "error": self.runtime.last_error,
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
                        self._refresh(decision.kind, stale)
                else:
                    if decision.reason == "unchanged":
                        self._pending_since = None

            self._wake.wait(self.config.poll_interval_s)
            self._wake.clear()

    def _refresh(self, kind: str, stale: bool) -> None:
        image = self.renderer.render(
            self.snapshot,
            stale=stale,
            mode=self.runtime.mode,
            updated_at=datetime.now().astimezone(),
        )
        if self.config.orientation == 180:
            image = image.rotate(180)
        try:
            self.display.show(image, kind=kind)
        except Exception as error:
            self.runtime.last_error = f"display: {error}"
            self._display_retry_at = time.time() + 60
            self._force = None
            self._pending_since = None
            logger.exception("display refresh failed")
            return
        self._save_preview(image)
        now_wall = time.time()
        self.policy.record(self.snapshot, stale=stale, kind=kind)
        self.runtime.last_refresh_at = now_wall
        self.runtime.last_refresh_kind = kind
        self._display_retry_at = 0.0
        self._force = None
        self._pending_since = None
        self._save_state()
        logger.info("displayed %s refresh", kind)

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
        mode = obj.get("mode")
        if mode in {"dashboard", "claude", "codex"}:
            self.runtime.mode = mode
        bridge = obj.get("bridge_url")
        if isinstance(bridge, str) and bridge:
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
