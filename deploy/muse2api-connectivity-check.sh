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
LOCAL_HEALTH_FAILURES="${MUSE2API_LOCAL_HEALTH_FAILURES:-3}"
LOCAL_HEALTH_INTERVAL="${MUSE2API_LOCAL_HEALTH_INTERVAL:-3}"
RESTART_WAIT_SECONDS="${MUSE2API_RESTART_WAIT_SECONDS:-60}"
RESTART_COOLDOWN_SECONDS="${MUSE2API_RESTART_COOLDOWN_SECONDS:-600}"
STATE_DIR="${MUSE2API_CONNECTIVITY_STATE_DIR:-/run/muse2api-connectivity}"
LAST_RESTART_FILE="$STATE_DIR/last-restart"

if [[ $EUID -ne 0 ]]; then
  echo "必须以 root 运行" >&2
  exit 2
fi

mkdir -p "$STATE_DIR"

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
  curl -fsS --connect-timeout 2 --max-time 5 "$HEALTH_URL" >/dev/null 2>&1
}

check_local_service_repeatedly() {
  local attempt
  for ((attempt = 1; attempt <= LOCAL_HEALTH_FAILURES; attempt++)); do
    if check_local_service; then
      if (( attempt > 1 )); then
        log "本地服务健康检查恢复 attempt=$attempt/$LOCAL_HEALTH_FAILURES"
      fi
      return 0
    fi
    log "本地服务健康检查失败 attempt=$attempt/$LOCAL_HEALTH_FAILURES url=$HEALTH_URL"
    if (( attempt < LOCAL_HEALTH_FAILURES )); then
      sleep "$LOCAL_HEALTH_INTERVAL"
    fi
  done
  return 1
}

wait_for_local_service() {
  local elapsed
  for ((elapsed = 1; elapsed <= RESTART_WAIT_SECONDS; elapsed++)); do
    if check_local_service; then
      log "本地服务已恢复 elapsed=${elapsed}s"
      return 0
    fi
    if (( elapsed == 1 || elapsed % 10 == 0 )); then
      log "等待本地服务恢复 elapsed=${elapsed}s/${RESTART_WAIT_SECONDS}s"
    fi
    sleep 1
  done
  return 1
}

restart_allowed() {
  local now last
  now="$(date +%s)"
  if [[ -r "$LAST_RESTART_FILE" ]]; then
    last="$(cat "$LAST_RESTART_FILE" 2>/dev/null || true)"
    if [[ "$last" =~ ^[0-9]+$ ]] && (( now - last < RESTART_COOLDOWN_SECONDS )); then
      log "仍在自动重启冷却期，跳过重启 remaining=$((RESTART_COOLDOWN_SECONDS - now + last))s"
      return 1
    fi
  fi
  return 0
}

mark_restart() {
  date +%s > "$LAST_RESTART_FILE"
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

if ! check_local_service_repeatedly; then
  log "尝试恢复本地服务 service=$SERVICE"
  if ! restart_allowed; then
    log "本地服务连续失败但未执行重启，请检查 service=$SERVICE"
    exit 1
  fi
  log "重启前状态 $(systemctl show "$SERVICE" -p ActiveState -p SubState -p MainPID -p NRestarts --value 2>/dev/null | paste -sd, -)"
  mark_restart
  systemctl restart "$SERVICE"
  wait_for_local_service || {
    log "本地服务重启后仍不健康 service=$SERVICE wait=${RESTART_WAIT_SECONDS}s"
    exit 1
  }
fi

exit 0
