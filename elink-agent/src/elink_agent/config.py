from __future__ import annotations

import os
import tomllib
from dataclasses import dataclass
from pathlib import Path


@dataclass(slots=True)
class AgentConfig:
    bridge_url: str = "http://127.0.0.1:8765"
    listen_host: str = "0.0.0.0"
    listen_port: int = 8766
    poll_interval_s: float = 2.0
    request_timeout_s: float = 3.0
    stale_after_s: int = 90
    display_driver: str = "mock"
    output_path: Path = Path("/var/lib/elink-ai/last-frame.png")
    state_path: Path = Path("/var/lib/elink-ai/state.json")
    font_path: str = ""
    min_refresh_interval_s: float = 30.0
    coalesce_s: float = 2.0
    full_refresh_every: int = 20
    full_refresh_interval_s: int = 21600
    orientation: int = 0
    display_keep_awake_s: float = 0.0
    monitor_enabled: bool = False
    monitor_idle_after_s: int = 300
    monitor_min_dwell_s: float = 300.0
    monitor_refresh_interval_s: float = 60.0
    monitor_net_sample_interval_s: float = 5.0
    bridge_url_env_override: str | None = None

    @classmethod
    def load(cls, path: str | os.PathLike[str] | None) -> "AgentConfig":
        config = cls()
        if path and Path(path).exists():
            with open(path, "rb") as handle:
                data = tomllib.load(handle)
            agent = data.get("agent", {})
            display = data.get("display", {})
            refresh = data.get("refresh", {})
            monitor = data.get("monitor", {})
            config.bridge_url = str(agent.get("bridge_url", config.bridge_url)).rstrip("/")
            config.listen_host = str(agent.get("listen_host", config.listen_host))
            config.listen_port = int(agent.get("listen_port", config.listen_port))
            config.poll_interval_s = float(agent.get("poll_interval_s", config.poll_interval_s))
            config.request_timeout_s = float(agent.get("request_timeout_s", config.request_timeout_s))
            config.stale_after_s = int(agent.get("stale_after_s", config.stale_after_s))
            config.display_driver = str(display.get("driver", config.display_driver))
            config.output_path = Path(display.get("output_path", config.output_path))
            config.state_path = Path(display.get("state_path", config.state_path))
            config.font_path = str(display.get("font_path", config.font_path))
            config.orientation = int(display.get("orientation", config.orientation))
            config.display_keep_awake_s = float(
                display.get("keep_awake_s", config.display_keep_awake_s))
            config.min_refresh_interval_s = float(refresh.get("min_interval_s", config.min_refresh_interval_s))
            config.coalesce_s = float(refresh.get("coalesce_s", config.coalesce_s))
            config.full_refresh_every = int(refresh.get("full_every", config.full_refresh_every))
            config.full_refresh_interval_s = int(refresh.get("full_interval_s", config.full_refresh_interval_s))
            config.monitor_enabled = bool(monitor.get("enabled", config.monitor_enabled))
            config.monitor_idle_after_s = int(monitor.get("idle_after_s", config.monitor_idle_after_s))
            config.monitor_min_dwell_s = float(monitor.get("min_dwell_s", config.monitor_min_dwell_s))
            config.monitor_refresh_interval_s = float(monitor.get("refresh_interval_s", config.monitor_refresh_interval_s))
            config.monitor_net_sample_interval_s = float(monitor.get("net_sample_interval_s", config.monitor_net_sample_interval_s))
        override = os.getenv("ELINK_BRIDGE_URL")
        if override:
            config.bridge_url = override.rstrip("/")
            config.bridge_url_env_override = config.bridge_url
        return config
