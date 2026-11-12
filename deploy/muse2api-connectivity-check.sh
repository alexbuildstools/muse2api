#!/usr/bin/env bash
set -Eeuo pipefail

# External Muse connectivity and local service self-healing check.
# This script is intended to run as root from a systemd timer.

CONFIG_FILE="${MUSE2API_CONNECTIVITY_CONFIG:-/etc/default/muse2api-connectivity}"
if [[ -r "$CONFIG_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$CONFIG_FILE"
fi

SERVICE="${MUSE2API_SERVICE:-muse2api-python.service}"
HEALTH_URL="${MUSE2API_HEALTH_URL:-http://127.0.0.1:18610/healthz}"
HATCH_URL="${MUSE2API_HATCH_URL:-https://hatch.metaaivm.com/v1/noise}"
HATCH_HOST="${MUSE2API_HATCH_HOST:-hatch.metaaivm.com}"
DNS_SERVERS="${MUSE2API_DNS_SERVERS:-1.1.1.1 8.8.8.8}"
DNS_INTERFACE="${MUSE2API_DNS_INTERFACE:-}"
AUTO_REPAIR="${MUSE2API_AUTO_REPAIR:-1}"
RESTART_ON_RECOVERY="${MUSE2API_RESTART_ON_RECOVERY:-1}"

if [[ $EUID -ne 0 ]]; then
  echo "必须以 root 运行" >&2
  exit 2
fi

log() {
  echo "[muse2api-connectivity] $*"
}

current_interface() {
  if [[ -n "$DNS_INTERFACE" ]]; then
    printf '%s\n' "$DNS_INTERFACE"
    return 0
  fi
  ip -o route show default 2>/dev/null | awk 'NR == 1 { print $5; exit }'
}

resolved_ipv4() {
  getent ahostsv4 "$HATCH_HOST" 2>/dev/null \
    | awk '{ print $1 }' \
    | sort -u \
    | tr '\n' ' ' \
    | sed 's/[[:space:]]*$//' || true
}

check_hatch() {
  local status
  status="$(curl -4 -sS -o /dev/null -w '%{http_code}' \
    --connect-timeout 5 --max-time 15 \
    -H 'Connection: Upgrade' \
    -H 'Upgrade: websocket' \
    -H 'Sec-WebSocket-Version: 13' \
    -H 'Sec-WebSocket-Key: SGVsbG9XU0tleQ==' \
    "$HATCH_URL" 2>/dev/null || true)"

  # A 401/403/404 is expected here because this probe does not carry the
  # browser's WebSocket authentication. Any HTTP response proves TCP/TLS
  # reached the Muse edge; 000 means the network connection failed.
  if [[ "$status" =~ ^[1-5][0-9]{2}$ ]]; then
    log "Hatch 网络正常 status=$status ips=$(resolved_ipv4)"
    return 0
  fi

  log "Hatch 网络失败 status=${status:-000} ips=$(resolved_ipv4)"
  return 1
}

check_local_service() {
  if curl -fsS --connect-timeout 2 --max-time 5 "$HEALTH_URL" >/dev/null 2>&1; then
    return 0
  fi
  log "本地服务健康检查失败 url=$HEALTH_URL"
  return 1
}

repair_dns() {
  local iface
  iface="$(current_interface)"
  if [[ -z "$iface" ]]; then
    log "无法确定默认网络接口，跳过 DNS 修复"
    return 1
  fi
  if ! command -v resolvectl >/dev/null 2>&1; then
    log "未找到 resolvectl，跳过 DNS 修复"
    return 1
  fi

  # Use word splitting intentionally: DNS_SERVERS is a space-separated list.
  # shellcheck disable=SC2086
  resolvectl dns "$iface" $DNS_SERVERS
  resolvectl domain "$iface" '~.'
  resolvectl flush-caches
  log "已刷新 DNS 接口=$iface servers=$DNS_SERVERS"
}

restart_service() {
  if [[ "$RESTART_ON_RECOVERY" != "1" ]]; then
    log "DNS 修复后网络已恢复，按配置不重启服务"
    return 0
  fi
  log "DNS 修复后网络恢复，重启服务 service=$SERVICE"
  systemctl try-restart "$SERVICE"
}

if ! check_hatch; then
  if [[ "$AUTO_REPAIR" == "1" ]] && repair_dns; then
    sleep 2
    if check_hatch; then
      restart_service
    else
      log "切换 DNS 后 Hatch 仍不可达；请检查服务器出口、代理或线路"
      exit 1
    fi
  else
    log "未执行自动 DNS 修复"
    exit 1
  fi
fi

if ! check_local_service; then
  log "尝试恢复本地服务 service=$SERVICE"
  systemctl restart "$SERVICE"
  sleep 2
  check_local_service || {
    log "本地服务重启后仍不健康"
    exit 1
  }
fi

exit 0
