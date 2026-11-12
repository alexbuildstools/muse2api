#!/usr/bin/env bash
set -Eeuo pipefail

APP_DIR="${MUSE2API_APP_DIR:-/home/muse2api}"
OUTPUT_DIR="${MUSE2API_BACKUP_DIR:-/var/backups/muse2api}"
INCLUDE_MEDIA=1
INCLUDE_PROFILES=0
PROFILES_DIR="${MUSE2API_PROFILE_ROOT:-/root/muse2api-profiles}"

usage() {
  cat <<'EOF'
用法：
  sudo bash deploy/backup-muse2api.sh [选项]

选项：
  --output DIR          备份输出目录，默认 /var/backups/muse2api
  --no-media            不包含 data/media 和 data/downloads
  --include-profiles    包含浏览器 profile，默认不包含
  --profiles-dir DIR    浏览器 profile 目录，默认 /root/muse2api-profiles
  -h, --help            显示帮助

注意：备份包含 Cookie、API Key 和账号数据，必须妥善保管。
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --output)
      [[ $# -ge 2 ]] || { echo "--output 缺少目录" >&2; exit 2; }
      OUTPUT_DIR="$2"
      shift 2
      ;;
    --no-media)
      INCLUDE_MEDIA=0
      shift
      ;;
    --include-profiles)
      INCLUDE_PROFILES=1
      shift
      ;;
    --profiles-dir)
      [[ $# -ge 2 ]] || { echo "--profiles-dir 缺少目录" >&2; exit 2; }
      PROFILES_DIR="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "未知参数：$1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ $EUID -ne 0 ]]; then
  echo "请使用 sudo 运行备份脚本" >&2
  exit 2
fi
if [[ ! -d "$APP_DIR" ]]; then
  echo "项目目录不存在：$APP_DIR" >&2
  exit 1
fi

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/muse2api-backup.XXXXXX")"
ARCHIVE="${OUTPUT_DIR%/}/muse2api-backup-${STAMP}.tar.gz"
trap 'rm -rf "$WORK_DIR"' EXIT

mkdir -p "$WORK_DIR/app" "$WORK_DIR/systemd" "$WORK_DIR/default" "$WORK_DIR/metadata"
mkdir -p "$OUTPUT_DIR"
chmod 700 "$WORK_DIR" "$OUTPUT_DIR"

TAR_EXCLUDES=(
  --exclude=.venv
  --exclude=venv
  --exclude='__pycache__'
  --exclude='*.pyc'
  --exclude='.pytest_cache'
  --exclude='*.log'
  --exclude='*.tar'
  --exclude='*.tar.gz'
  --exclude='*.zip'
)
if [[ "$INCLUDE_MEDIA" != "1" ]]; then
  TAR_EXCLUDES+=(--exclude='data/media/*' --exclude='data/downloads/*')
fi

echo "打包项目文件：$APP_DIR"
tar -C "$APP_DIR" "${TAR_EXCLUDES[@]}" -cf - . | tar -C "$WORK_DIR/app" -xf -

if [[ "$INCLUDE_PROFILES" == "1" ]]; then
  if [[ -d "$PROFILES_DIR" ]]; then
    echo "打包浏览器 profile：$PROFILES_DIR"
    mkdir -p "$WORK_DIR/profiles"
    tar -C "$PROFILES_DIR" \
      --exclude='Cache' --exclude='Code Cache' --exclude='GPUCache' \
      --exclude='ShaderCache' --exclude='Crash Reports' \
      -cf - . | tar -C "$WORK_DIR/profiles" -xf -
  else
    echo "警告：profile 目录不存在，跳过：$PROFILES_DIR" >&2
  fi
fi

for unit in \
  muse2api-python.service \
  muse2api.service \
  muse2api-connectivity-check.service \
  muse2api-connectivity-check.timer; do
  if [[ -f "/etc/systemd/system/$unit" ]]; then
    cp -a "/etc/systemd/system/$unit" "$WORK_DIR/systemd/$unit"
  fi
done
if [[ -f /etc/default/muse2api-connectivity ]]; then
  cp -a /etc/default/muse2api-connectivity "$WORK_DIR/default/muse2api-connectivity"
fi

{
  echo "created_at_utc=$STAMP"
  echo "app_dir=$APP_DIR"
  echo "include_media=$INCLUDE_MEDIA"
  echo "include_profiles=$INCLUDE_PROFILES"
  if git -C "$APP_DIR" rev-parse HEAD >/dev/null 2>&1; then
    echo "git_commit=$(git -C "$APP_DIR" rev-parse HEAD)"
  fi
  echo
  echo "=== systemd service ==="
  systemctl cat muse2api-python.service 2>&1 || true
  echo
  echo "=== DNS status ==="
  resolvectl status 2>&1 || true
} > "$WORK_DIR/metadata/manifest.txt"

echo "生成备份包：$ARCHIVE"
tar -C "$WORK_DIR" -czf "$ARCHIVE" .
chmod 600 "$ARCHIVE"
sha256sum "$ARCHIVE" > "$ARCHIVE.sha256"
chmod 600 "$ARCHIVE.sha256"

echo
echo "备份完成："
echo "  文件：$ARCHIVE"
echo "  校验：$ARCHIVE.sha256"
echo "  大小：$(du -h "$ARCHIVE" | awk '{print $1}')"
echo "  权限：仅 root 可读"
