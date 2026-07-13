#!/bin/sh
set -eu

if [ "$(id -u)" -ne 0 ]; then
  echo "Run this installer with sudo." >&2
  exit 1
fi

SOURCE_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
apt-get update
apt-get install -y python3-venv python3-dev python3-setuptools python3-pil fonts-dejavu-core python3-spidev python3-gpiozero

install -d /opt/elink-ai /etc/elink-ai /var/lib/elink-ai
cp -a "$SOURCE_DIR/elink-agent" "$SOURCE_DIR/pyproject.toml" /opt/elink-ai/
python3 -m venv --system-site-packages /opt/elink-ai/.venv
/opt/elink-ai/.venv/bin/pip install --no-deps --no-build-isolation /opt/elink-ai

if [ ! -f /etc/elink-ai/config.toml ]; then
  install -m 0644 "$SOURCE_DIR/install/config.example.toml" /etc/elink-ai/config.toml
fi
install -m 0644 "$SOURCE_DIR/install/elink-agent.service" /etc/systemd/system/elink-agent.service

if command -v raspi-config >/dev/null 2>&1; then
  raspi-config nonint do_spi 0
fi
systemctl daemon-reload
systemctl enable elink-agent.service

echo "Edit /etc/elink-ai/config.toml, then run:"
echo "  sudo systemctl restart elink-agent"
echo "  journalctl -u elink-agent -f"
