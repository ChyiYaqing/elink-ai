from dataclasses import replace

import time

from elink_agent.system_monitor import SystemMonitor


def test_poll_returns_sane_snapshot():
    mon = SystemMonitor(net_sample_interval_s=0.5).poll()
    assert mon.hostname
    assert mon.uptime_s >= 0
    assert mon.mem_total_kb > 0
    assert mon.disk_total > 0
    assert 0 <= mon.mem_percent <= 100
    assert 0 <= mon.disk_percent <= 100
    assert 0 <= mon.disk_used <= mon.disk_total
    assert mon.load_1m >= 0 and mon.load_5m >= 0 and mon.load_15m >= 0


def test_second_poll_produces_cpu_percent_and_net_rates():
    monitor = SystemMonitor(net_sample_interval_s=0.1)
    monitor.poll()
    time.sleep(0.2)
    second = monitor.poll()
    assert second.cpu_percent is not None
    assert 0 <= second.cpu_percent <= 100
    # 第一次 poll 建立了基线，间隔满足后第二次应给出速率
    assert second.net_rx_bps is not None
    assert second.net_tx_bps is not None
    assert second.net_rx_bps >= 0 and second.net_tx_bps >= 0


def test_signature_is_stable_and_changes_with_data():
    mon = SystemMonitor(net_sample_interval_s=0.1).poll()
    assert isinstance(mon.signature(), str)
    assert mon.signature() == mon.signature()
    changed = replace(mon, load_1m=round(mon.load_1m + 10.0, 1))
    assert changed.signature() != mon.signature()
