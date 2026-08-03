from __future__ import annotations

import argparse
import json
import time
from pathlib import Path
from urllib.request import Request, urlopen

MAX_DEVICE_BYTES = 1_048_576


def fetch_device(url: str, timeout_s: float) -> dict:
    request = Request(url, headers={"Accept": "application/json",
                                    "User-Agent": "elink-soak-monitor/1"})
    with urlopen(request, timeout=timeout_s) as response:
        if response.status != 200:
            raise OSError(f"device returned HTTP {response.status}")
        body = response.read(MAX_DEVICE_BYTES + 1)
        if len(body) > MAX_DEVICE_BYTES:
            raise OSError("device response is too large")
        value = json.loads(body)
    if not isinstance(value, dict):
        raise ValueError("device response must be a JSON object")
    return value


def run(*, url: str, output: Path, duration_s: float, interval_s: float,
        timeout_s: float = 5.0) -> dict:
    if duration_s <= 0 or interval_s <= 0:
        raise ValueError("duration and interval must be positive")
    output.parent.mkdir(parents=True, exist_ok=True)
    started = time.time()
    deadline = time.monotonic() + duration_s
    samples = 0
    errors = 0
    previous_counts: dict[str, int] | None = None
    count_delta: dict[str, int] = {}
    previous_uptime: int | None = None
    agent_restarts = 0
    with output.open("a", buffering=1) as stream:
        while True:
            sampled_at = time.time()
            try:
                device = fetch_device(url, timeout_s)
                counts = device.get("refresh_counts")
                if isinstance(counts, dict):
                    normalized = {str(key): int(value) for key, value in counts.items()}
                    if previous_counts is not None:
                        reset = any(normalized.get(key, 0) < previous_counts.get(key, 0)
                                    for key in set(normalized) | set(previous_counts))
                        for key in set(normalized) | set(previous_counts):
                            increment = (normalized.get(key, 0) if reset else
                                         normalized.get(key, 0) - previous_counts.get(key, 0))
                            count_delta[key] = count_delta.get(key, 0) + max(0, increment)
                    previous_counts = normalized
                uptime = device.get("process_uptime_s")
                if isinstance(uptime, int):
                    if previous_uptime is not None and uptime < previous_uptime:
                        agent_restarts += 1
                    previous_uptime = uptime
                record = {"event": "sample", "sampled_at": sampled_at, "device": device}
            except Exception as error:
                errors += 1
                record = {"event": "sample-error", "sampled_at": sampled_at,
                          "error": str(error)}
            stream.write(json.dumps(record, separators=(",", ":")) + "\n")
            samples += 1
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                break
            time.sleep(min(interval_s, remaining))
        summary = {
            "event": "summary",
            "started_at": started,
            "finished_at": time.time(),
            "samples": samples,
            "sample_errors": errors,
            "agent_restarts": agent_restarts,
            "refresh_count_delta": count_delta,
        }
        stream.write(json.dumps(summary, separators=(",", ":")) + "\n")
    return summary


def main() -> None:
    parser = argparse.ArgumentParser(description="Record elink-agent D4 soak telemetry")
    parser.add_argument("--url", default="http://127.0.0.1:8766/v1/device")
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--duration-s", type=float, default=24 * 60 * 60)
    parser.add_argument("--interval-s", type=float, default=60)
    args = parser.parse_args()
    print(json.dumps(run(url=args.url, output=args.output, duration_s=args.duration_s,
                         interval_s=args.interval_s)))


if __name__ == "__main__":
    main()
