#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

if [[ $EUID -ne 0 ]]; then
  echo "请使用 sudo 运行此安装脚本" >&2
  exit 2
fi

install -D -m 0755 \
  "$SCRIPT_DIR/muse2api-daily-restart.sh.example" \
  /usr/local/sbin/muse2api-daily-restart
install -D -m 0644 \
  "$SCRIPT_DIR/muse2api-daily-restart.service.example" \
  /etc/systemd/system/muse2api-daily-restart.service
install -D -m 0644 \
  "$SCRIPT_DIR/muse2api-daily-restart.timer.example" \
  /etc/systemd/system/muse2api-daily-restart.timer

systemctl daemon-reload
systemctl enable --now muse2api-daily-restart.timer

echo "每日定时重启已启用（服务器本地时间约 04:00，随机延迟最多 5 分钟）："
systemctl status muse2api-daily-restart.timer --no-pager
echo
echo "查看执行日志：journalctl -u muse2api-daily-restart.service -n 50 --no-pager"
