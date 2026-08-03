import json

from elink_agent import soak_monitor


def test_soak_monitor_records_samples_errors_and_counter_delta(tmp_path, monkeypatch):
    calls = 0

    def fetch(_url, _timeout):
        nonlocal calls
        calls += 1
        if calls == 2:
            raise OSError("temporary failure")
        return {"refresh_counts": {"region": calls, "full": 1}, "error": None}

    monkeypatch.setattr(soak_monitor, "fetch_device", fetch)
    output = tmp_path / "soak.jsonl"

    summary = soak_monitor.run(
        url="http://device/v1/device", output=output,
        duration_s=0.2, interval_s=0.01,
    )

    records = [json.loads(line) for line in output.read_text().splitlines()]
    assert summary["samples"] >= 3
    assert summary["sample_errors"] == 1
    assert summary["refresh_count_delta"]["region"] >= 2
    assert summary["agent_restarts"] == 0
    assert records[-1] == summary


def test_soak_monitor_accumulates_across_agent_counter_reset(tmp_path, monkeypatch):
    values = [(5, 100), (6, 101), (1, 1), (2, 2)]
    calls = 0

    def fetch(_url, _timeout):
        nonlocal calls
        region, uptime = values[min(calls, len(values) - 1)]
        calls += 1
        return {"refresh_counts": {"region": region}, "process_uptime_s": uptime}

    monkeypatch.setattr(soak_monitor, "fetch_device", fetch)
    summary = soak_monitor.run(
        url="http://device/v1/device", output=tmp_path / "reset.jsonl",
        duration_s=0.12, interval_s=0.01,
    )

    assert summary["agent_restarts"] == 1
    assert summary["refresh_count_delta"]["region"] == 3
