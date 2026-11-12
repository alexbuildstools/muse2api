#!/usr/bin/env bash
set -Eeuo pipefail

APP_DIR="${MUSE2API_APP_DIR:-/home/muse2api}"
MEDIA_SOURCE="${MUSE2API_MEDIA_LINK:-$APP_DIR/data/media}"
MEDIA_TARGET="${MUSE2API_MEDIA_TARGET:-/mnt/mydisk/muse2api-media}"
MEDIA_MOUNTPOINT="${MUSE2API_MEDIA_MOUNTPOINT:-/mnt/mydisk}"
ALLOW_MERGE=0

usage() {
  cat <<'EOF'
用法：
  sudo bash deploy/migrate-media-to-disk.sh
  sudo bash deploy/migrate-media-to-disk.sh --merge

默认行为：
  目标目录必须为空，避免覆盖媒体盘中已有文件。
  --merge 允许把旧目录内容合并到目标目录，目标中同名文件可能被覆盖。
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --merge) ALLOW_MERGE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "未知参数：$1" >&2; usage >&2; exit 2 ;;
  esac
done

if [[ $EUID -ne 0 ]]; then
  echo "请使用 sudo 运行迁移脚本" >&2
  exit 2
fi
if ! command -v rsync >/dev/null 2>&1; then
  echo "缺少 rsync，请先安装：sudo apt-get install -y rsync" >&2
  exit 1
fi
if ! mountpoint -q "$MEDIA_MOUNTPOINT"; then
  echo "媒体盘未挂载：$MEDIA_MOUNTPOINT" >&2
  exit 1
fi
if [[ -L "$MEDIA_SOURCE" ]]; then
  if [[ "$(readlink -f "$MEDIA_SOURCE")" == "$(readlink -f "$MEDIA_TARGET")" ]]; then
    echo "媒体软连接已经正确，无需迁移：$MEDIA_SOURCE -> $MEDIA_TARGET"
    exit 0
  fi
  echo "旧媒体目录不存在，或已经是其他软连接：$MEDIA_SOURCE" >&2
  exit 1
fi
if [[ ! -d "$MEDIA_SOURCE" ]]; then
  echo "旧媒体目录不存在：$MEDIA_SOURCE" >&2
  exit 1
fi

mkdir -p "$MEDIA_TARGET"
if [[ "$ALLOW_MERGE" != "1" ]] &&
   [[ -n "$(find "$MEDIA_TARGET" -mindepth 1 -maxdepth 1 -print -quit)" ]]; then
  echo "目标目录非空：$MEDIA_TARGET" >&2
  echo "为避免覆盖目标文件，已停止。确认要合并时使用 --merge。" >&2
  exit 1
fi

echo "复制媒体文件：$MEDIA_SOURCE -> $MEDIA_TARGET"
rsync -a --human-readable --info=progress2 "$MEDIA_SOURCE"/ "$MEDIA_TARGET"/

echo "校验复制结果..."
REMAINING="$(rsync -a --dry-run --itemize-changes \
  "$MEDIA_SOURCE"/ "$MEDIA_TARGET"/)"
if [[ -n "$REMAINING" ]]; then
  echo "校验失败，未创建软连接；仍有差异：" >&2
  echo "$REMAINING" >&2
  exit 1
fi

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
OLD_DIR="${MEDIA_SOURCE}.pre-migration-${STAMP}"
echo "保留旧目录：$MEDIA_SOURCE -> $OLD_DIR"
mv "$MEDIA_SOURCE" "$OLD_DIR"
if ! ln -s "$MEDIA_TARGET" "$MEDIA_SOURCE"; then
  echo "创建软连接失败，正在回滚旧目录" >&2
  mv "$OLD_DIR" "$MEDIA_SOURCE"
  exit 1
fi

echo "迁移完成："
echo "  软连接：$MEDIA_SOURCE -> $MEDIA_TARGET"
echo "  旧目录：$OLD_DIR"
echo "确认新服务运行正常后，旧目录可以人工删除。"
