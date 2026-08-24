from dataclasses import replace

import subprocess

import pytest

from elink_agent.system_monitor import SystemMonitor

LOADAVG = "1.25 0.80 0.55 2/531 12345\n"
MEMINFO = """MemTotal:        8000000 kB
MemFree:         1000000 kB
MemAvailable:    6000000 kB
Buffers:          200000 kB
"""
UPTIME = "90061.42 350000.00\n"
NETDEV = """Inter-|   Receive                                       |  Transmit
 face |bytes packets errs drop fifo frame compressed multicast|bytes packets errs drop fifo colls carrier compressed
    lo: 1000 10 0 0 0 0 0 0 1000 10 0 0 0 0 0 0
  eth0: 5000 50 0 0 0 0 0 0 2000 20 0 0 0 0 0 0
"""
NETDEV_LATER = NETDEV.replace(
    "  eth0: 5000 50 0 0 0 0 0 0 2000 20 0 0 0 0 0 0",
    "  eth0: 25000 90 0 0 0 0 0 0 12000 40 0 0 0 0 0 0",
)
# user nice system idle iowait ...：两帧之间 total +200、idle +100 → 忙 50%
STAT = "cpu  100 0 100 800 0 0 0 0 0 0\ncpu0 100 0 100 800 0 0 0 0 0 0\n"
STAT_LATER = "cpu  150 0 150 900 0 0 0 0 0 0\ncpu0 150 0 150 900 0 0 0 0 0 0\n"


@pytest.fixture
def proc(tmp_path, monkeypatch):
    """把采样器指向一棵假的 /proc，让断言在任何操作系统上都成立。"""
    files = {"LOADAVG": LOADAVG, "MEMINFO": MEMINFO, "UPTIME": UPTIME,
             "NETDEV": NETDEV, "STAT": STAT, "THERMAL_ZONE": "47000\n"}
    paths = {}
    for attr, text in files.items():
        path = tmp_path / attr.lower()
        path.write_text(text)
        paths[attr] = path
        monkeypatch.setattr(SystemMonitor, attr, str(path))
    return paths


def test_poll_parses_proc_files(proc):
    mon = SystemMonitor(net_sample_interval_s=0.5).poll()
    assert (mon.load_1m, mon.load_5m, mon.load_15m) == (1.25, 0.80, 0.55)
    assert mon.mem_total_kb == 8_000_000
    assert mon.mem_available_kb == 6_000_000
    assert mon.mem_percent == pytest.approx(25.0)
    assert mon.temp_c == pytest.approx(47.0)
    assert mon.uptime_s == pytest.approx(90061.42)
    # lo 不计入总量
    assert (mon.net_rx_total, mon.net_tx_total) == (5000, 2000)
    assert mon.hostname
    assert 0 <= mon.disk_percent <= 100
    assert 0 <= mon.disk_used <= mon.disk_total


def test_poll_on_this_host_never_raises():
    mon = SystemMonitor(net_sample_interval_s=0.5).poll()
    assert mon.hostname
    assert mon.uptime_s >= 0
    assert mon.disk_total > 0
    assert 0 <= mon.mem_percent <= 100
    assert 0 <= mon.disk_percent <= 100
    assert mon.load_1m >= 0 and mon.load_5m >= 0 and mon.load_15m >= 0


def test_second_poll_produces_cpu_percent_and_net_rates(proc):
    monitor = SystemMonitor(net_sample_interval_s=0.1)
    first = monitor.poll()
    # 第一次 poll 只建立基线
    assert first.cpu_percent is None
    assert first.net_rx_bps is None

    proc["STAT"].write_text(STAT_LATER)
    proc["NETDEV"].write_text(NETDEV_LATER)
    # 假装上一次采样发生在 10 秒前，速率才不依赖测试的真实耗时
    monitor._prev_net_ts -= 10.0
    second = monitor.poll()
    assert second.cpu_percent == pytest.approx(50.0)
    assert second.net_rx_bps == pytest.approx(2000.0, rel=0.01)
    assert second.net_tx_bps == pytest.approx(1000.0, rel=0.01)


def test_counter_resets_do_not_produce_negative_rates(proc):
    monitor = SystemMonitor(net_sample_interval_s=0.1)
    monitor.poll()
    proc["NETDEV"].write_text(NETDEV.replace("  eth0: 5000", "  eth0: 10"))
    monitor._prev_net_ts -= 10.0
    second = monitor.poll()
    assert second.net_rx_bps == 0.0
    assert second.net_tx_bps == 0.0


def test_missing_vcgencmd_is_probed_only_once(proc, monkeypatch, tmp_path):
    monkeypatch.setattr(SystemMonitor, "THERMAL_ZONE", str(tmp_path / "absent"))
    calls = []

    def fake_run(*args, **kwargs):
        calls.append(args)
        raise FileNotFoundError("vcgencmd")

    monkeypatch.setattr(subprocess, "run", fake_run)
    monitor = SystemMonitor(net_sample_interval_s=0.1)
    assert monitor.poll().temp_c is None
    assert monitor.poll().temp_c is None
    assert len(calls) == 1


def test_signature_is_stable_and_changes_with_data(proc):
    mon = SystemMonitor(net_sample_interval_s=0.1).poll()
    assert isinstance(mon.signature(), str)
    assert mon.signature() == mon.signature()
    changed = replace(mon, load_1m=round(mon.load_1m + 10.0, 1))
    assert changed.signature() != mon.signature()
