from __future__ import annotations

import socket
import subprocess
import time
from collections import deque
from dataclasses import dataclass, field
from pathlib import Path
from shutil import disk_usage


def _read_proc(path: str) -> list[str]:
    try:
        return Path(path).read_text().splitlines()
    except OSError:
        return []


@dataclass(slots=True)
class NetTotals:
    rx_bytes: int = 0
    tx_bytes: int = 0


@dataclass(slots=True)
class MonitorSnapshot:
    """一帧设备监控快照。所有值都是采样时的原始读数，单位在字段名里写明。"""

    ts: float
    load_1m: float
    load_5m: float
    load_15m: float
    cpu_percent: float | None
    mem_total_kb: int
    mem_available_kb: int
    mem_percent: float
    disk_total: int
    disk_used: int
    disk_percent: float
    temp_c: float | None
    uptime_s: float
    net_rx_bps: float | None
    net_tx_bps: float | None
    net_rx_total: int
    net_tx_total: int
    hostname: str
    # 最近若干次采样的 CPU 使用率，旧→新。给监控页画趋势条用。
    cpu_history: tuple[float, ...] = field(default_factory=tuple)

    def signature(self) -> str:
        """变化的粒度：足够细以反映实时状态，但网络速率取整到 KiB/s 避免抖刷新。"""
        return repr((
            round(self.load_1m, 1),
            round(self.load_5m, 1),
            round(self.load_15m, 1),
            None if self.cpu_percent is None else round(self.cpu_percent),
            round(self.mem_percent),
            round(self.disk_percent),
            None if self.temp_c is None else round(self.temp_c, 1),
            int(self.uptime_s // 60),
            int(self.net_rx_bps // 1024) if self.net_rx_bps is not None else None,
            int(self.net_tx_bps // 1024) if self.net_tx_bps is not None else None,
        ))


class SystemMonitor:
    LOADAVG = "/proc/loadavg"
    MEMINFO = "/proc/meminfo"
    UPTIME = "/proc/uptime"
    NETDEV = "/proc/net/dev"
    STAT = "/proc/stat"
    THERMAL_ZONE = "/sys/class/thermal/thermal_zone0/temp"
    HISTORY_SAMPLES = 30

    def __init__(self, *, net_sample_interval_s: float = 5.0):
        self.net_sample_interval_s = max(0.1, net_sample_interval_s)
        self._cpu_history: deque[float] = deque(maxlen=self.HISTORY_SAMPLES)
        self._hostname = socket.gethostname()
        self._prev_cpu: tuple[int, int] | None = None
        self._prev_net: NetTotals | None = None
        self._prev_net_ts: float | None = None
        self._vcgencmd_missing = False
        self._rate_rx_bps: float | None = None
        self._rate_tx_bps: float | None = None

    def poll(self) -> MonitorSnapshot:
        now = time.time()
        load = self._loadavg()
        cpu_percent = self._cpu_percent()
        mem_total, mem_available = self._memory()
        mem_percent = (
            100.0 * (mem_total - mem_available) / mem_total if mem_total else 0.0
        )
        disk_total, disk_used, disk_percent = self._disk()
        temp_c = self._temperature()
        uptime_s = self._uptime()
        rx, tx = self._net_totals()
        self._update_rates(now, rx, tx)
        if cpu_percent is not None:
            self._cpu_history.append(cpu_percent)
        return MonitorSnapshot(
            ts=now,
            load_1m=load[0],
            load_5m=load[1],
            load_15m=load[2],
            cpu_percent=cpu_percent,
            mem_total_kb=mem_total,
            mem_available_kb=mem_available,
            mem_percent=mem_percent,
            disk_total=disk_total,
            disk_used=disk_used,
            disk_percent=disk_percent,
            temp_c=temp_c,
            uptime_s=uptime_s,
            net_rx_bps=self._rate_rx_bps,
            net_tx_bps=self._rate_tx_bps,
            net_rx_total=rx,
            net_tx_total=tx,
            hostname=self._hostname,
            cpu_history=tuple(self._cpu_history),
        )

    def _update_rates(self, now: float, rx: int, tx: int) -> None:
        if self._prev_net is None:
            self._prev_net = NetTotals(rx_bytes=rx, tx_bytes=tx)
            self._prev_net_ts = now
            return
        dt = now - (self._prev_net_ts or 0.0)
        if dt < self.net_sample_interval_s:
            return
        self._rate_rx_bps = max(0.0, (rx - self._prev_net.rx_bytes) / dt)
        self._rate_tx_bps = max(0.0, (tx - self._prev_net.tx_bytes) / dt)
        self._prev_net = NetTotals(rx_bytes=rx, tx_bytes=tx)
        self._prev_net_ts = now

    @staticmethod
    def _loadavg() -> tuple[float, float, float]:
        lines = _read_proc(SystemMonitor.LOADAVG)
        if not lines:
            return 0.0, 0.0, 0.0
        parts = lines[0].split()
        try:
            return float(parts[0]), float(parts[1]), float(parts[2])
        except (IndexError, ValueError):
            return 0.0, 0.0, 0.0

    def _cpu_percent(self) -> float | None:
        lines = _read_proc(SystemMonitor.STAT)
        if not lines or not lines[0].startswith("cpu "):
            return None
        try:
            numbers = [int(field) for field in lines[0].split()[1:]]
        except ValueError:
            return None
        total = sum(numbers)
        idle = numbers[3] + (numbers[4] if len(numbers) > 4 else 0)  # idle + iowait
        if self._prev_cpu is not None:
            dt_total = total - self._prev_cpu[0]
            dt_idle = idle - self._prev_cpu[1]
            self._prev_cpu = (total, idle)
            if dt_total <= 0:
                return None
            busy = dt_total - dt_idle
            return max(0.0, min(100.0, 100.0 * busy / dt_total))
        self._prev_cpu = (total, idle)
        return None

    @staticmethod
    def _memory() -> tuple[int, int]:
        total = available = 0
        for line in _read_proc(SystemMonitor.MEMINFO):
            if line.startswith("MemTotal:"):
                total = int(line.split()[1]) if len(line.split()) > 1 else 0
            elif line.startswith("MemAvailable:"):
                available = int(line.split()[1]) if len(line.split()) > 1 else 0
        return total, available

    @staticmethod
    def _disk() -> tuple[int, int, float]:
        try:
            usage = disk_usage("/")
        except OSError:
            return 0, 0, 0.0
        percent = 100.0 * usage.used / usage.total if usage.total else 0.0
        return usage.total, usage.used, percent

    def _temperature(self) -> float | None:
        try:
            value = int(Path(SystemMonitor.THERMAL_ZONE).read_text().strip())
            return value / 1000.0
        except (OSError, ValueError):
            pass
        # 没有 vcgencmd 的机器（任何非树莓派）不必每次采样都再 fork 一次去确认
        if self._vcgencmd_missing:
            return None
        return self._vcgencmd_temperature()

    def _vcgencmd_temperature(self) -> float | None:
        try:
            output = subprocess.run(
                ["vcgencmd", "measure_temp"],
                capture_output=True,
                text=True,
                timeout=2,
            ).stdout
        except FileNotFoundError:
            self._vcgencmd_missing = True
            return None
        except (OSError, subprocess.SubprocessError):
            return None
        try:
            raw = output.split("=", 1)[-1].strip().replace("'C", "").replace("C", "")
            return float(raw)
        except ValueError:
            return None

    @staticmethod
    def _uptime() -> float:
        lines = _read_proc(SystemMonitor.UPTIME)
        if not lines:
            return 0.0
        try:
            return float(lines[0].split()[0])
        except (IndexError, ValueError):
            return 0.0

    @staticmethod
    def _net_totals() -> tuple[int, int]:
        rx = tx = 0
        for line in _read_proc(SystemMonitor.NETDEV)[2:]:
            if ":" not in line:
                continue
            name, rest = line.split(":", 1)
            if name.strip() == "lo":
                continue
            fields = rest.split()
            if len(fields) < 9:
                continue
            try:
                rx += int(fields[0])
                tx += int(fields[8])
            except ValueError:
                continue
        return rx, tx
