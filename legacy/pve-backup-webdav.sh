#!/usr/bin/env bash
#
# PVE 备份 + WebDAV 上传（独立服务，不使用 vzdump 钩子）
#
# 流程:
#   1. 调用 vzdump 执行一次完整备份（前台阻塞，等待退出码）
#   2. 找出本次新生成的归档
#   3. 逐个上传到 WebDAV，校验大小（可选 SHA256）
#   4. 执行远端保留策略
#
# 用法:
#   pve-backup-webdav.sh              备份 + 上传
#   pve-backup-webdav.sh --upload-only  只扫描并补传未上传的本地备份（幂等）
#
# 配置: /etc/pve-backup-webdav.conf
# 日志: /var/log/pve-backup-webdav.log

set -uo pipefail

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export HOME="/root"
export XDG_CONFIG_HOME="/root/.config"
RCLONE_CONFIG="/root/.config/rclone/rclone.conf"

CONF="/etc/pve-backup-webdav.conf"
LOG="/var/log/pve-backup-webdav.log"
LOCK="/run/pve-backup-webdav.lock"
MARKER="/run/pve-backup-webdav.marker"

log() {
    printf '%s %s\n' "$(date '+%F %T')" "$*" >>"$LOG"
}

RUN_MODE="backup"
case "${1:-}" in
    "")               ;;
    --upload-only)    RUN_MODE="upload" ;;
    -h|--help)        echo "用法: $0 [--upload-only]"; exit 0 ;;
    *)                echo "未知参数: $1" >&2; exit 2 ;;
esac

if [ ! -r "$CONF" ]; then
    log "错误: 找不到配置文件 $CONF"
    exit 1
fi

# shellcheck source=/dev/null
. "$CONF"

: "${VMIDS:=all}"
: "${STORAGE:=local}"
: "${BACKUP_MODE:=snapshot}"
: "${COMPRESS:=zstd}"
: "${LOCAL_PRUNE:=keep-last=3}"
: "${DUMPDIR:=/var/lib/vz/dump}"
: "${RCLONE_REMOTE:=webdav}"
: "${REMOTE_SUBDIR:=pve-backups}"
: "${REMOTE_RETENTION:=}"
: "${DELETE_LOCAL:=0}"
: "${VERIFY_HASH:=0}"
: "${UPLOAD_FAILURE_FATAL:=1}"
: "${RCLONE_RETRIES:=5}"
: "${RCLONE_TIMEOUT:=10m}"

REMOTE_DIR="${RCLONE_REMOTE}:${REMOTE_SUBDIR}"

# 防止定时任务与手动执行重叠
exec 9>"$LOCK"
if ! flock -w 3600 9; then
    log "错误: 等待运行锁超时，已有实例在运行"
    exit 1
fi

upload_file() {
    local file="$1" base size remote_size lh rh

    base=$(basename "$file")
    size=$(stat -c %s "$file")

    # 幂等：远端已存在且大小一致则跳过
    remote_size=$(rclone lsl "$REMOTE_DIR/$base" --config "$RCLONE_CONFIG" 2>/dev/null \
        | awk 'NR==1{print $1}')
    if [ "$remote_size" = "$size" ]; then
        log "跳过（远端已存在且大小一致）: $base"
        return 0
    fi

    log "开始上传 $base ($(numfmt --to=iec "$size" 2>/dev/null || echo "$size B"))"

    if ! rclone copyto "$file" "$REMOTE_DIR/$base" \
            --config "$RCLONE_CONFIG" \
            --checksum \
            --retries "$RCLONE_RETRIES" \
            --low-level-retries 20 \
            --timeout "$RCLONE_TIMEOUT" \
            --contimeout 30s \
            --stats 30s \
            --log-file "$LOG" \
            --log-level INFO; then
        log "上传失败: $base"
        return 1
    fi

    remote_size=$(rclone lsl "$REMOTE_DIR/$base" --config "$RCLONE_CONFIG" 2>/dev/null \
        | awk 'NR==1{print $1}')
    if [ "$remote_size" != "$size" ]; then
        log "大小校验失败: $base 本地 $size / 远端 ${remote_size:-未知}"
        return 1
    fi

    if [ "$VERIFY_HASH" = "1" ]; then
        lh=$(sha256sum "$file" | awk '{print $1}')
        rh=$(rclone cat "$REMOTE_DIR/$base" --config "$RCLONE_CONFIG" 2>/dev/null \
            | sha256sum | awk '{print $1}')
        if [ "$lh" != "$rh" ]; then
            log "SHA256 校验失败: $base"
            return 1
        fi
        log "SHA256 一致: $lh"
    fi

    log "上传完成并校验通过: $base ($size 字节)"

    if [ "$DELETE_LOCAL" = "1" ]; then
        if rm -f "$file"; then
            log "已删除本地备份: $base"
        else
            log "警告: 删除本地备份失败: $base"
        fi
    fi

    return 0
}

# ---------- 1. 备份 ----------
if [ "$RUN_MODE" = "backup" ]; then
    touch "$MARKER"
    log "===== 开始备份 (VM: $VMIDS, 存储: $STORAGE, 模式: $BACKUP_MODE, 压缩: $COMPRESS) ====="

    if [ "$VMIDS" = "all" ]; then
        vzdump --all \
            --storage "$STORAGE" \
            --mode "$BACKUP_MODE" \
            --compress "$COMPRESS" \
            --prune-backups "$LOCAL_PRUNE" >>"$LOG" 2>&1
    else
        # shellcheck disable=SC2086
        vzdump $VMIDS \
            --storage "$STORAGE" \
            --mode "$BACKUP_MODE" \
            --compress "$COMPRESS" \
            --prune-backups "$LOCAL_PRUNE" >>"$LOG" 2>&1
    fi
    rc=$?

    if [ "$rc" -ne 0 ]; then
        log "备份失败 (vzdump 退出码 $rc)，不执行上传"
        exit 1
    fi
    log "vzdump 执行成功 (退出码 0)"

    mapfile -t FILES < <(find "$DUMPDIR" -maxdepth 1 -type f \
        -name 'vzdump-*.vma.zst' -newer "$MARKER" 2>/dev/null | sort)
else
    log "===== 仅上传模式：扫描本地尚未上传的备份 ====="
    mapfile -t FILES < <(find "$DUMPDIR" -maxdepth 1 -type f \
        -name 'vzdump-*.vma.zst' 2>/dev/null | sort)
fi

# ---------- 2. 上传 ----------
if [ "${#FILES[@]}" -eq 0 ]; then
    log "没有需要上传的备份文件"
    exit 0
fi

FAIL=0
for f in "${FILES[@]}"; do
    upload_file "$f" || FAIL=1
done

# ---------- 3. 远端保留策略 ----------
if [ -n "$REMOTE_RETENTION" ]; then
    if rclone delete "$REMOTE_DIR" \
            --config "$RCLONE_CONFIG" \
            --min-age "$REMOTE_RETENTION" \
            --include "vzdump-*.vma.*" \
            --log-file "$LOG" \
            --log-level INFO; then
        log "远端保留策略执行完成 (min-age=$REMOTE_RETENTION)"
    else
        log "警告: 远端保留策略执行失败"
    fi
fi

if [ "$FAIL" -ne 0 ]; then
    log "===== 本次执行结束，但存在上传失败（可用 --upload-only 重试） ====="
    [ "$UPLOAD_FAILURE_FATAL" = "1" ] && exit 1
    exit 0
fi

log "===== 本次执行全部成功 ====="
exit 0
