# elink-ai

`elink-ai` shows Claude Code and Codex activity and quota on a 648×480
Waveshare 5.83 inch V2 e-paper display.

It has two deliberately separate processes:

- `mac-app/`: a native macOS menu-bar bridge. It reads local CLI credentials
  and JSONL sessions, fetches quota, accepts CLI hooks, and serves sanitized
  status on port 8765.
- `elink-agent/`: a Raspberry Pi service. It polls the bridge, renders a 1-bit
  dashboard, applies refresh throttling, and drives the panel over SPI/GPIO.

OAuth tokens and raw session logs never leave the Mac.

## Current scope

- Claude and Codex side-by-side dashboard
- 5-hour and weekly usage/reset time
- today's token count and working/idle/offline state
- attention border for permission requests
- smart, partial, periodic full, and manual full refresh
- stale/offline display, last-frame preview, and persistent device settings
- menu-bar device discovery, page switching, refresh, and preview

The LCD-specific pet animation, music, and network graphs from `esp8266-ai`
are intentionally excluded because they conflict with e-paper refresh limits.

## Develop the Pi agent without hardware

Python 3.11+ and Pillow are required.

```bash
python3 -m venv .venv
.venv/bin/pip install -e '.[test]'
cp install/config.example.toml /tmp/elink-ai.toml
# Change driver to "mock" and choose writable /tmp output/state paths.
.venv/bin/elink-agent --config /tmp/elink-ai.toml
```

The device API is then available at `http://localhost:8766/v1/device`, and the
last rendered image at `http://localhost:8766/v1/preview.png`.

Run tests with:

```bash
.venv/bin/pytest -q
```

## Run the macOS bridge

On macOS 13 or later with Xcode command-line tools:

```bash
cd mac-app
swift test
swift run ElinkAIBridge
```

The app runs only in the menu bar. Right-click controls the Pi; left-click
opens the exact PNG last sent to the display. Verify the bridge with:

```bash
curl -s http://localhost:8765/v1/status | python3 -m json.tool
```

Build an ad-hoc-signed menu-bar app bundle with:

```bash
cd mac-app
sh build-app.sh
open .build/ElinkAIBridge.app
```

After copying it to `/Applications`, the example LaunchAgent in `install/` can
start it at login.

Claude hooks can be merged without replacing existing settings:

```bash
python3 hooks/install-claude-hooks.py
```

The installer saves `~/.claude/settings.json.elink-ai.bak`. Codex hook schemas
are still evolving; the bridge endpoint supports Codex events, but this version
does not rewrite Codex configuration automatically. Log mtime detection remains
active for both providers.

## Install on Raspberry Pi

First edit `install/config.example.toml` or edit the installed copy afterward,
especially `bridge_url`. Then:

```bash
sudo sh install/install-pi.sh
sudo editor /etc/elink-ai/config.toml
sudo systemctl restart elink-agent
journalctl -u elink-agent -f
```

The installer enables SPI and installs a root systemd service. Start with the
mock driver if the exact panel revision or wiring is uncertain. Hardware wiring
and partial-refresh cautions are in [docs/hardware.md](docs/hardware.md).

## APIs and security

The versioned protocol is documented in [docs/protocol.md](docs/protocol.md).
Both services use unauthenticated HTTP and are intended only for a trusted LAN.
Do not expose ports 8765 or 8766 to the public internet.

## License and provenance

The project is GPL-3.0-only. The isolated Waveshare adapter follows the public
Waveshare 5.83 V2 command sequence and the GPL-licensed InkyPi integration.
The macOS implementation was rewritten for this repository around the observed
data flow; it does not include the ESP8266 firmware or its display assets.

See [PLAN.md](PLAN.md) for architecture decisions, rollout phases, risks, and
acceptance criteria.
