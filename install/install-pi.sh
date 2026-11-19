#!/bin/sh
set -eu

if [ "$(id -u)" -ne 0 ]; then
  echo "Run this installer with sudo." >&2
  exit 1
fi

SOURCE_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
apt-get update
apt-get install -y python3-venv python3-dev python3-setuptools python3-pil fonts-dejavu-core python3-spidev python3-gpiozero python3-cryptography

install -d /opt/elink-ai /etc/elink-ai /var/lib/elink-ai
# 已安装的源码是自动更新的回滚基线，更新器以 root 从它重新安装，
# 所以必须属于 root 且其他用户不可写（不能用 cp -a 保留 checkout 的属主）。
SOURCE=/opt/elink-ai/source-install
rm -rf "$SOURCE"
mkdir "$SOURCE"
cp -R "$SOURCE_DIR/elink-agent" "$SOURCE_DIR/pyproject.toml" "$SOURCE/"
chown -R root:root "$SOURCE"
chmod -R go-w "$SOURCE"
ln -sfn source-install /opt/elink-ai/source
python3 -m venv --system-site-packages /opt/elink-ai/.venv
/opt/elink-ai/.venv/bin/pip install --no-deps --no-build-isolation /opt/elink-ai/source/

if [ ! -f /etc/elink-ai/config.toml ]; then
  install -m 0644 "$SOURCE_DIR/install/config.example.toml" /etc/elink-ai/config.toml
fi
install -m 0644 "$SOURCE_DIR/install/elink-agent.service" /etc/systemd/system/elink-agent.service
install -m 0644 "$SOURCE_DIR/install/elink-agent-update.service" /etc/systemd/system/elink-agent-update.service
install -m 0644 "$SOURCE_DIR/install/elink-agent-update.timer" /etc/systemd/system/elink-agent-update.timer

if command -v raspi-config >/dev/null 2>&1; then
  raspi-config nonint do_spi 0
fi
systemctl daemon-reload
systemctl enable elink-agent.service
systemctl enable --now elink-agent-update.timer

echo "Edit /etc/elink-ai/config.toml, then run:"
echo "  sudo systemctl restart elink-agent"
echo "  journalctl -u elink-agent -f"
