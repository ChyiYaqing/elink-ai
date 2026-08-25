# Waveshare 5.83 inch V2 wiring

The initial hardware profile matches the panel validated by the neighboring
InkyPi checkout:

| Signal | Raspberry Pi BCM | Physical role |
|---|---:|---|
| RST | 17 | panel reset |
| DC | 25 | data/command |
| BUSY | 24 | busy input, active low |
| PWR | 18 | display power enable |
| CS | 8 / CE0 | SPI chip select |
| MOSI | 10 | SPI0 MOSI |
| SCLK | 11 | SPI0 clock |

The driver uses SPI bus 0, device 0, mode 0 at 4 MHz and a 60-second BUSY
timeout. Confirm the exact panel revision and cable orientation before enabling
the hardware driver. Start with `driver = "mock"`; inspect `last-frame.png`,
then switch to `waveshare_5in83_v2` and request one full refresh.

`partial` and `smart` requests compare the rendered frame with the last frame
successfully sent to the panel. Small changes use byte-aligned rectangular
windows; changes covering more than 35% of the screen use a full-frame fast
waveform. A missing or uncertain baseline uses a full refresh. If ghosting is
unacceptable, set `full_every = 1` to disable non-full automatic refreshes.

## Validation record

On 2026-07-13 the adapter was exercised on the connected Raspberry Pi and
648×480 panel with the neighboring InkyPi service stopped. A full dashboard
refresh, a Claude-only partial refresh, and a final full dashboard refresh all
completed without BUSY timeout. SPI0 ran at 4 MHz and the system reported
`throttled=0x0`. Long-running ghosting behavior still needs the documented
24-hour soak test before reducing the conservative refresh limits.

## Region-refresh baseline

To verify the low-level command sequence independently of the production
frame-diff path, stop the service and run the isolated region test:

```bash
sudo systemctl stop elink-agent
sudo PYTHONPATH=/opt/elink-ai/elink-agent/src \
  /usr/bin/python3 -m elink_agent.display.region_baseline \
  --iterations 1 \
  --restore /var/lib/elink-ai/last-frame.png \
  --confirm-hardware-refresh
sudo systemctl start elink-agent
```

The test performs a full baseline, updates only the center rectangle, and
restores the saved dashboard with a full refresh. Its JSON lines record BUSY
duration and transferred bytes. Keep the production service stopped so two
processes never access SPI/GPIO concurrently.

### D0 smoke record

On 2026-07-30 the isolated test ran on the `3BP` aarch64 Raspberry Pi at
648×480. The full baseline took 4.741 seconds, the 264×144 center region took
1.244 seconds, and the final full restore took 4.746 seconds. The region sent
4,752 bytes instead of the full refresh's two 38,880-byte buffers, a 93.9%
reduction. All operations completed without a BUSY timeout; the service was
restarted, performed a full dashboard refresh, and reported no device error.

This proves the command path, byte count, and BUSY completion. Visual boundary
correctness and ghosting still require the planned multi-cycle observation;
do not enable region refresh in `AgentService` from this smoke result alone.

A second run performed five alternating black/white updates of the same region.
Each update completed in 1.249–1.259 seconds with the same 4,752-byte payload,
followed by a successful 4.749-second full restore and service restart. No BUSY
timeout or device error occurred. Because the Pi has no available camera, a
human still needs to confirm that only the center rectangle changed and that
the final full refresh removed any visible residue.

On 2026-07-31 a 30-second visible test completed the D0 visual gate. The
observer confirmed that only the center rectangle changed, the four corner
markers did not flicker or move, and the recovery full refresh left no visible
residue on the restored dashboard. D0 and the pure-software D1 frame-diff work
were therefore allowed to proceed to production integration.

### D2 production integration record

On 2026-07-31 the production frame-diff and region driver were deployed to
`3BP`. The first refresh after restart used `full` because no in-memory
displayed-frame baseline existed. The next real data change used `region` with
four windows and a combined planned area of 1,112 pixels; the service remained
active and reported no BUSY, SPI, or display error. A later broad change crossed
the 35% threshold and selected `fast-full`, while an immediately repeated smart
request logged that the identical rendered frame was skipped.

Automated tests also cover BUSY timeout cleanup, SPI/display failure baseline
invalidation, and the following recovery refresh selecting `full`. The runtime
API exposes the actual operation, region count, planned area, and selection
reason so these decisions can be checked without inferring them from the
requested refresh kind.

### D3/D4 live validation

On 2026-08-03 the bridge began publishing at most three sanitized current
sessions and recent state transitions. The production preview showed the
Claude error badge and Codex current-session row inside their reserved provider
regions; prompts, transcript snippets, and full paths were absent from the live
status response.

The D4 telemetry build reports cumulative counts for `full`, `fast-full`,
`region`, skipped, and failed operations, plus planned area, display duration,
and time spent waiting for BUSY. Per the shortened validation requested for this
release, `3BP` produced 163 samples at one-minute intervals from 2026-08-03
10:03 CST, covering 9,722.6 seconds (about 2 h 42 min) in
`/var/lib/elink-ai/soak-d4-20260803-v2.jsonl`. There were no sample errors,
stale samples, refresh failures, or agent restarts; uptime advanced from 84 to
9,806 seconds. Counters advanced from `full=1, fast-full=0, region=2` to
`full=5, fast-full=2, region=91`, with `skipped=0, failed=0`; 155 samples ended
with a region operation. Region refreshes were about 1.24 s with about 0.42 s
BUSY wait. The 24-hour ambient run is intentionally deferred; defaults remain
unchanged and the shorter window is the evidence used for this release.

### Refresh-cost breakdown and the keep-awake window

On 2026-08-25 the per-refresh cost was measured on `3BP` while the device
monitor page was on screen. A region refresh took 1.25 s end to end, made up
of 402 ms of reset delays, 200 ms of power-on and pre-refresh delays, 200 ms
closing the deep sleep, 423 ms of BUSY, 6 ms of SPI for a 3 KB payload, and
52 ms of agent work (rendering the frame, diffing it, and saving the preview).
Only the BUSY portion is the panel imaging; the rest was the driver walking the
whole power-up and power-down cycle for every update.

With `[display] keep_awake_s = 10`, refreshes that land inside the window skip
the reset and the closing sleep, and a region refresh takes 463-480 ms with
342-353 ms of BUSY. The first refresh after the window closes pays for
initialisation again at 990-1024 ms. A full refresh takes 4.5 s.

The window runs from the moment the panel wakes and is not extended by later
refreshes, so continuous powered time is bounded. This matters: Waveshare
requires the panel to be put to sleep when it is not being refreshed, because
sitting powered holds it under high voltage and can damage it permanently. A
renewing window would keep a page that ticks every few seconds powered
indefinitely. The default is 0, which sleeps and powers off after every
refresh as before, and the agent's main loop parks the panel as soon as the
window closes.

Note that a keep-awake window raises the share of time the panel spends
powered even though it lowers the cost of each refresh: at a 3.1 s cadence
with a 10 s window the panel is powered roughly 80% of the time, against
roughly 36% when every refresh ends asleep. The 24-hour soak test is still
outstanding, so treat a fast cadence combined with a keep-awake window as
unproven for long-term ghosting and panel life.
