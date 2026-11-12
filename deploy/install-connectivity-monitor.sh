#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

if [[ $EUID -ne 0 ]]; then
  echo "请使用 sudo 运行此安装脚本" >&2
  exit 2
fi

install -D -m 0755 \
  "$SCRIPT_DIR/muse2api-connectivity-check.sh" \
  /usr/local/sbin/muse2api-connectivity-check
install -D -m 0644 \
  "$SCRIPT_DIR/muse2api-connectivity-check.service" \
  /etc/systemd/system/muse2api-connectivity-check.service
install -D -m 0644 \
  "$SCRIPT_DIR/muse2api-connectivity-check.timer" \
  /etc/systemd/system/muse2api-connectivity-check.timer

if [[ ! -e /etc/default/muse2api-connectivity ]]; then
  install -D -m 0644 \
    "$SCRIPT_DIR/muse2api-connectivity.env.example" \
    /etc/default/muse2api-connectivity
fi

systemctl daemon-reload
systemctl enable --now muse2api-connectivity-check.timer
systemctl start muse2api-connectivity-check.service

echo "监控已启用："
systemctl status muse2api-connectivity-check.timer --no-pager
echo
echo "查看检查日志：journalctl -u muse2api-connectivity-check.service -n 50 --no-pager"
