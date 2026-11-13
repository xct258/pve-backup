#!/usr/bin/env bash
#
# vzdump hook script: 备份完成后把归档上传到 WebDAV
#
# 由 vzdump 调用，参数为: <phase> <mode> <vmid>
# 仅在 backup-end 阶段执行，此时 $TARGET 指向已完成的备份文件。
#
# 相关配置见 /etc/pve-webdav.conf，rclone remote 见 /root/.config/rclone/rclone.conf

set -uo pipefail

# vzdump 调用钩子时会清空环境变量，这里显式恢复运行所需环境
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export HOME="/root"
export XDG_CONFIG_HOME="/root/.config"
RCLONE_CONFIG="/root/.config/rclone/rclone.conf"

PHASE="${1:-}"
MODE="${2:-}"
VMID="${3:-}"

CONF="/etc/pve-webdav.conf"
LOG="/var/log/pve-webdav-upload.log"
LOCK="/run/pve-webdav-upload.lock"

log() {
    printf '%s [%s vmid=%s] %s\n' "$(date '+%F %T')" "$PHASE" "${VMID:-?}" "$*" >> "$LOG"
}

[ "$PHASE" = "backup-end" ] || exit 0

if [ ! -r "$CONF" ]; then
    log "缺少配置文件 $CONF，跳过上传"
    exit 1
fi

# shellcheck source=/dev/null
. "$CONF"

: "${RCLONE_REMOTE:=webdav}"
: "${REMOTE_SUBDIR:=pve-backups}"
: "${RETENTION:=}"
: "${DELETE_LOCAL:=0}"
: "${RCLONE_RETRIES:=5}"
: "${RCLONE_TIMEOUT:=10m}"

if [ -z "${TARGET:-}" ] || [ ! -f "$TARGET" ]; then
    log "备份文件不存在 (TARGET=${TARGET:-空})，跳过上传"
    exit 1
fi

# 同一时间只允许一个上传任务，避免并发写远端
exec 9>"$LOCK"
if ! flock -w 3600 9; then
    log "等待上传锁超时，跳过上传"
    exit 1
fi

LOCAL_SIZE=$(stat -c %s "$TARGET")
BASENAME=$(basename "$TARGET")
REMOTE_DIR="${RCLONE_REMOTE}:${REMOTE_SUBDIR}"
REMOTE_FILE="${REMOTE_DIR}/${BASENAME}"

log "开始上传 $BASENAME ($(numfmt --to=iec "$LOCAL_SIZE" 2>/dev/null || echo "$LOCAL_SIZE B")) -> $REMOTE_FILE"

if ! rclone copyto "$TARGET" "$REMOTE_FILE" \
        --config "$RCLONE_CONFIG" \
        --checksum \
        --retries "$RCLONE_RETRIES" \
        --low-level-retries 20 \
        --timeout "$RCLONE_TIMEOUT" \
        --contimeout 30s \
        --stats 30s \
        --log-file "$LOG" \
        --log-level INFO; then
    log "上传失败: $BASENAME"
    exit 1
fi

REMOTE_SIZE=$(rclone lsl "$REMOTE_FILE" --config "$RCLONE_CONFIG" 2>/dev/null | awk 'NR==1{print $1}')

if [ "$REMOTE_SIZE" != "$LOCAL_SIZE" ]; then
    log "校验失败: 本地 $LOCAL_SIZE 字节, 远端 ${REMOTE_SIZE:-未知} 字节"
    exit 1
fi

log "上传完成并校验通过: $BASENAME ($REMOTE_SIZE 字节)"

if [ "$DELETE_LOCAL" = "1" ]; then
    if rm -f "$TARGET"; then
        log "已删除本地备份 $TARGET"
    else
        log "警告: 删除本地备份失败 $TARGET"
    fi
fi

# 远端保留策略：删除超过 RETENTION 的旧归档
if [ -n "$RETENTION" ]; then
    if rclone delete "$REMOTE_DIR" \
            --config "$RCLONE_CONFIG" \
            --min-age "$RETENTION" \
            --include "vzdump-*.vma.*" \
            --log-file "$LOG" \
            --log-level INFO; then
        log "已按保留策略清理 (min-age=$RETENTION)"
    else
        log "警告: 远端保留策略清理失败"
    fi
fi

exit 0
