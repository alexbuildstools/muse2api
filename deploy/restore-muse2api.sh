#!/usr/bin/env bash
set -Eeuo pipefail

APP_DIR="${MUSE2API_APP_DIR:-/home/muse2api}"
PROFILES_DIR="${MUSE2API_PROFILE_ROOT:-/root/muse2api-profiles}"
FORCE=0
BUNDLE=""

usage() {
  cat <<'EOF'
用法：
  sudo bash restore-muse2api.sh BACKUP.tar.gz [--force]

说明：
  默认要求目标目录不存在或为空。
  --force 会先把已有项目目录改名为 .pre-restore-时间戳，再恢复备份。
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --force) FORCE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    -*) echo "未知参数：$1" >&2; usage >&2; exit 2 ;;
    *)
      [[ -z "$BUNDLE" ]] || { echo "只能指定一个备份包" >&2; exit 2; }
      BUNDLE="$1"
      shift
      ;;
  esac
done

if [[ $EUID -ne 0 ]]; then
  echo "请使用 sudo 运行恢复脚本" >&2
  exit 2
fi
if [[ -z "$BUNDLE" || ! -f "$BUNDLE" ]]; then
  echo "备份包不存在：${BUNDLE:-<未指定>}" >&2
  usage >&2
  exit 2
fi

if [[ -f "$BUNDLE.sha256" ]]; then
  echo "校验备份包..."
  (cd "$(dirname "$BUNDLE")" && sha256sum -c "$(basename "$BUNDLE").sha256")
fi

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/muse2api-restore.XXXXXX")"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
trap 'rm -rf "$WORK_DIR"' EXIT
tar -xzf "$BUNDLE" -C "$WORK_DIR"
[[ -d "$WORK_DIR/app" ]] || { echo "备份包缺少 app 目录" >&2; exit 1; }

if [[ -d "$APP_DIR" ]] && [[ -n "$(find "$APP_DIR" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]]; then
  if [[ "$FORCE" != "1" ]]; then
    echo "目标目录非空：$APP_DIR；如确认覆盖，请增加 --force" >&2
    exit 1
  fi
  if systemctl is-active --quiet muse2api-python.service 2>/dev/null; then
    echo "停止现有服务：muse2api-python.service"
    systemctl stop muse2api-python.service
  fi
  OLD_DIR="${APP_DIR}.pre-restore-${STAMP}"
  echo "保留现有目录：$APP_DIR -> $OLD_DIR"
  mv "$APP_DIR" "$OLD_DIR"
fi

mkdir -p "$APP_DIR"
cp -a "$WORK_DIR/app/." "$APP_DIR/"
chmod 600 "$APP_DIR/.env" 2>/dev/null || true
chmod 600 "$APP_DIR/data/accounts.json" 2>/dev/null || true

if [[ -d "$WORK_DIR/profiles" ]]; then
  echo "恢复浏览器 profile：$PROFILES_DIR"
  mkdir -p "$PROFILES_DIR"
  cp -a "$WORK_DIR/profiles/." "$PROFILES_DIR/"
fi

if [[ ! -x "$APP_DIR/.venv/bin/python" ]]; then
  echo "创建 Python 虚拟环境..."
  python3 -m venv "$APP_DIR/.venv"
fi
echo "安装 Python 依赖..."
"$APP_DIR/.venv/bin/python" -m pip install -r "$APP_DIR/requirements.txt"

if [[ -d "$WORK_DIR/systemd" ]]; then
  for unit in "$WORK_DIR"/systemd/*; do
    [[ -f "$unit" ]] || continue
    install -m 0644 "$unit" "/etc/systemd/system/$(basename "$unit")"
  done
fi

if [[ -f "$WORK_DIR/default/muse2api-connectivity" ]]; then
  install -D -m 0644 "$WORK_DIR/default/muse2api-connectivity" \
    /etc/default/muse2api-connectivity
elif [[ -f "$APP_DIR/deploy/muse2api-connectivity.env.example" &&
      ! -f /etc/default/muse2api-connectivity ]]; then
  install -D -m 0644 "$APP_DIR/deploy/muse2api-connectivity.env.example" \
    /etc/default/muse2api-connectivity
fi

# A backup from the current production server contains this unit. For older
# bundles, fall back to the repository template with the production paths.
if [[ ! -f /etc/systemd/system/muse2api-python.service &&
      -f "$APP_DIR/deploy/muse2api-python.service.example" ]]; then
  install -m 0644 "$APP_DIR/deploy/muse2api-python.service.example" \
    /etc/systemd/system/muse2api-python.service
fi

systemctl daemon-reload
systemctl enable muse2api-python.service
systemctl restart muse2api-python.service

if [[ -f /etc/systemd/system/muse2api-connectivity-check.timer ]]; then
  systemctl enable --now muse2api-connectivity-check.timer
fi

echo "等待健康检查..."
for _ in $(seq 1 30); do
  if curl --connect-timeout 2 --max-time 5 -fsS \
      http://127.0.0.1:18610/healthz >/dev/null; then
    echo "恢复完成：$APP_DIR"
    systemctl --no-pager --full status muse2api-python.service || true
    exit 0
  fi
  sleep 1
done

echo "服务启动后健康检查失败" >&2
systemctl status muse2api-python.service --no-pager || true
journalctl -u muse2api-python.service -n 100 --no-pager -o cat || true
exit 1
