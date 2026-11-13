#!/usr/bin/env bash
#
# pve-backup.sh —— PVE 备份 + WebDAV 上传（单文件自包含）
#
# 特点:
#   * 不使用 vzdump 钩子，备份与上传由本脚本顺序编排
#   * install 子命令自动注册自身、配置、systemd 服务/定时器、日志轮转、rclone remote
#   * 每次执行后输出详细报告（耗时/大小/速率/校验/远端存量）
#
# 用法:
#   pve-backup.sh                         交互式菜单（无终端时显示状态，不执行备份）
#   pve-backup.sh menu                    交互式菜单
#   pve-backup.sh run                     执行一次备份+上传
#   pve-backup.sh upload                  只补传本地未上传的备份（幂等）
#   pve-backup.sh install [选项]          自动注册服务与定时器
#   pve-backup.sh uninstall               注销服务与定时器
#   pve-backup.sh status                  查看运行状态与存量
#   pve-backup.sh list                    列出本地/远端备份明细
#   pve-backup.sh config                  打印当前配置
#
# 快速注册示例:
#   ./pve-backup.sh install --vmid 100 --time 02:30 \
#       --url http://127.0.0.1:5244/dav --user webdav --pass 'xxx' \
#       --subdir 'dav/pve-backup'

set -uo pipefail

SELF_PATH="/usr/local/sbin/pve-backup.sh"
CONF="/etc/pve-backup.conf"
LOG="/var/log/pve-backup.log"
LOCK="/run/pve-backup.lock"
MARKER="/run/pve-backup.marker"
SERVICE_NAME="pve-backup-webdav.service"
TIMER_NAME="pve-backup-webdav.timer"
UNIT_DIR="/etc/systemd/system"
LOGROTATE_FILE="/etc/logrotate.d/pve-backup"

# ---------------- 默认配置（可被 $CONF 覆盖） ----------------
VMIDS="all"
STORAGE="local"
BACKUP_MODE="snapshot"
COMPRESS="zstd"
LOCAL_PRUNE="keep-last=3"
DUMPDIR="/var/lib/vz/dump"
RCLONE_REMOTE="webdav"
REMOTE_SUBDIR="pve-backups"
REMOTE_RETENTION="7d"
DELETE_LOCAL=0
VERIFY_HASH=0
UPLOAD_FAILURE_FATAL=1
SCHEDULE="02:30"
RCLONE_RETRIES=5
RCLONE_TIMEOUT="10m"
RCLONE_CONFIG="/root/.config/rclone/rclone.conf"

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export HOME="/root"
export XDG_CONFIG_HOME="/root/.config"

# ---------------- 输出helpers ----------------
hsize() { numfmt --to=iec-i --suffix=B "$1" 2>/dev/null || echo "${1}B"; }

log() { printf '%s %s\n' "$(date '+%F %T')" "$*" >>"$LOG"; }

# LOGGING=1 时 say 才写入日志，避免 status/list 自污染
LOGGING=0
say() {
    printf '%s\n' "$*"
    if [ "$LOGGING" = "1" ] && [ -n "$*" ]; then
        printf '%s %s\n' "$(date '+%F %T')" "$*" >>"$LOG"
    fi
    return 0
}

# 按显示宽度补空格（正确处理中文占 2 列）
pad() {
    python3 - "$1" "$2" <<'PY'
import sys, unicodedata
s, w = sys.argv[1], int(sys.argv[2])
d = sum(2 if unicodedata.east_asian_width(c) in "WF" else 1 for c in s)
sys.stdout.write(s + " " * max(0, w - d))
PY
}

# 状态行：标签按显示宽度对齐
row() {
    printf '  %s %s\n' "$(pad "$1" 10)" "$2"
}

section() {
    local title="$1"
    local line="────────────────────────────────────────────────────────────"
    say ""
    say "$line"
    say " $title"
    say "$line"
}

die() { say "错误: $*"; exit 1; }

need_root() { [ "$(id -u)" -eq 0 ] || die "需要 root 权限"; }

load_conf() {
    if [ -r "$CONF" ]; then
        # shellcheck source=/dev/null
        . "$CONF"
    fi
}

have_rclone_remote() {
    rclone listremotes --config "$RCLONE_CONFIG" 2>/dev/null | grep -qx "${RCLONE_REMOTE}:"
}

# ---------------- 上传 ----------------
UPLOAD_NAMES=()
UPLOAD_SIZES=()
UPLOAD_SECS=()
UPLOAD_SPEEDS=()
UPLOAD_RESULTS=()

upload_file() {
    local file="$1" base size t0 t1 dur speed remote_size rc

    base=$(basename "$file")
    size=$(stat -c %s "$file")

    remote_size=$(rclone lsl "${RCLONE_REMOTE}:${REMOTE_SUBDIR}/${base}" \
        --config "$RCLONE_CONFIG" 2>/dev/null | awk 'NR==1{print $1}')

    if [ "$remote_size" = "$size" ]; then
        say "  [跳过] $base —— 远端已存在且大小一致"
        UPLOAD_NAMES+=("$base"); UPLOAD_SIZES+=("$size")
        UPLOAD_SECS+=("0"); UPLOAD_SPEEDS+=("0"); UPLOAD_RESULTS+=("skipped")
        return 0
    fi

    say "  [上传] $base ($(hsize "$size"))"

    t0=$(date +%s)
    rclone copyto "$file" "${RCLONE_REMOTE}:${REMOTE_SUBDIR}/${base}" \
        --config "$RCLONE_CONFIG" \
        --checksum \
        --retries "$RCLONE_RETRIES" \
        --low-level-retries 20 \
        --timeout "$RCLONE_TIMEOUT" \
        --contimeout 30s \
        --stats 5s \
        --stats-one-line \
        --log-level INFO 2>&1 | tee -a "$LOG"
    rc=${PIPESTATUS[0]}
    t1=$(date +%s)
    dur=$(( t1 - t0 )); [ "$dur" -lt 1 ] && dur=1

    if [ "$rc" -ne 0 ]; then
        say "  [失败] $base —— rclone 退出码 $rc"
        UPLOAD_NAMES+=("$base"); UPLOAD_SIZES+=("$size")
        UPLOAD_SECS+=("$dur"); UPLOAD_SPEEDS+=("0"); UPLOAD_RESULTS+=("failed")
        return 1
    fi

    remote_size=$(rclone lsl "${RCLONE_REMOTE}:${REMOTE_SUBDIR}/${base}" \
        --config "$RCLONE_CONFIG" 2>/dev/null | awk 'NR==1{print $1}')
    if [ "$remote_size" != "$size" ]; then
        say "  [失败] $base —— 大小不一致 本地=$size 远端=${remote_size:-未知}"
        UPLOAD_NAMES+=("$base"); UPLOAD_SIZES+=("$size")
        UPLOAD_SECS+=("$dur"); UPLOAD_SPEEDS+=("0"); UPLOAD_RESULTS+=("failed")
        return 1
    fi

    if [ "$VERIFY_HASH" = "1" ]; then
        local lh rh
        say "  [校验] 计算 SHA256 ..."
        lh=$(sha256sum "$file" | awk '{print $1}')
        rh=$(rclone cat "${RCLONE_REMOTE}:${REMOTE_SUBDIR}/${base}" \
            --config "$RCLONE_CONFIG" 2>/dev/null | sha256sum | awk '{print $1}')
        if [ "$lh" != "$rh" ]; then
            say "  [失败] $base —— SHA256 不一致"
            UPLOAD_NAMES+=("$base"); UPLOAD_SIZES+=("$size")
            UPLOAD_SECS+=("$dur"); UPLOAD_SPEEDS+=("0"); UPLOAD_RESULTS+=("failed")
            return 1
        fi
        say "  [校验] SHA256 一致: $lh"
    fi

    speed=$(( size / dur ))
    say "  [完成] $base 用时 ${dur}s，平均 $(hsize "$speed")/s"

    UPLOAD_NAMES+=("$base"); UPLOAD_SIZES+=("$size")
    UPLOAD_SECS+=("$dur"); UPLOAD_SPEEDS+=("$speed"); UPLOAD_RESULTS+=("ok")

    if [ "$DELETE_LOCAL" = "1" ]; then
        rm -f "$file" && say "  [清理] 已删除本地 $base" || say "  [警告] 删除本地失败: $base"
    fi

    return 0
}

# ---------------- 备份+上传 ----------------
cmd_run() {
    need_root
    LOGGING=1
    load_conf

    if [ ! -r "$CONF" ]; then
        say "未找到配置 $CONF，将使用默认值；建议先执行: $0 install"
    fi

    exec 9>"$LOCK"
    flock -w 3600 9 || die "等待运行锁超时，已有实例在运行"

    if ! have_rclone_remote; then
        die "rclone remote '${RCLONE_REMOTE}' 不存在，请先 install 或配置 rclone"
    fi

    section "PVE 备份开始 $(date '+%F %T')"
    say "  目标     : $VMIDS"
    say "  存储     : $STORAGE ($DUMPDIR)"
    say "  模式     : $BACKUP_MODE"
    say "  压缩     : $COMPRESS"
    say "  本地保留 : $LOCAL_PRUNE"
    say "  远端     : ${RCLONE_REMOTE}:${REMOTE_SUBDIR}"
    say "  远端保留 : ${REMOTE_RETENTION:-不清理}"
    [ "$DELETE_LOCAL" = "1" ] && say "  本地副本 : 上传成功后删除"

    touch "$MARKER"

    local t_start t_backup_done rc
    t_start=$(date +%s)

    say ""
    say ">>> 调用 vzdump ..."
    if [ "$VMIDS" = "all" ]; then
        vzdump --all \
            --storage "$STORAGE" --mode "$BACKUP_MODE" \
            --compress "$COMPRESS" --prune-backups "$LOCAL_PRUNE" 2>&1 | tee -a "$LOG"
    else
        # shellcheck disable=SC2086
        vzdump $VMIDS \
            --storage "$STORAGE" --mode "$BACKUP_MODE" \
            --compress "$COMPRESS" --prune-backups "$LOCAL_PRUNE" 2>&1 | tee -a "$LOG"
    fi
    rc=${PIPESTATUS[0]}
    t_backup_done=$(date +%s)

    if [ "$rc" -ne 0 ]; then
        say ""
        say "!!! vzdump 失败 (退出码 $rc)，本次不上传"
        section "结果: 失败"
        return 1
    fi

    local -a files=()
    mapfile -t files < <(find "$DUMPDIR" -maxdepth 1 -type f \
        -name 'vzdump-*.vma.zst' -newer "$MARKER" 2>/dev/null | sort)

    if [ "${#files[@]}" -eq 0 ]; then
        say "未发现本次新生成的归档，可能被保留策略立即清理"
        return 0
    fi

    section "上传到 WebDAV"
    local fail=0 f
    for f in "${files[@]}"; do
        upload_file "$f" || fail=1
    done

    # 远端保留
    local retention_msg="未启用"
    if [ -n "$REMOTE_RETENTION" ]; then
        say ""
        say ">>> 执行远端保留策略 (min-age=$REMOTE_RETENTION) ..."
        if rclone delete "${RCLONE_REMOTE}:${REMOTE_SUBDIR}" \
                --config "$RCLONE_CONFIG" \
                --min-age "$REMOTE_RETENTION" \
                --include "vzdump-*.vma.*" \
                --log-level INFO 2>&1 | tee -a "$LOG"; then
            retention_msg="已执行 (min-age=$REMOTE_RETENTION)"
        else
            retention_msg="执行失败"
            fail=1
        fi
    fi

    # ---------- 详细报告 ----------
    local t_end total_sec backup_sec upload_sec total_size
    t_end=$(date +%s)
    total_sec=$(( t_end - t_start ))
    backup_sec=$(( t_backup_done - t_start ))

    local remote_count remote_bytes local_count local_bytes
    remote_count=$(rclone lsf "${RCLONE_REMOTE}:${REMOTE_SUBDIR}" \
        --config "$RCLONE_CONFIG" --files-only 2>/dev/null | wc -l)
    remote_bytes=$(rclone size "${RCLONE_REMOTE}:${REMOTE_SUBDIR}" \
        --config "$RCLONE_CONFIG" --json 2>/dev/null \
        | python3 -c 'import sys,json;print(json.load(sys.stdin).get("bytes",0))' 2>/dev/null || echo 0)
    local_count=$(find "$DUMPDIR" -maxdepth 1 -type f -name 'vzdump-*.vma.zst' 2>/dev/null | wc -l)
    local_bytes=$(du -cb "$DUMPDIR"/vzdump-*.vma.zst 2>/dev/null | tail -1 | awk '{print $1}')

    total_size=0; upload_sec=0
    local i
    for i in "${!UPLOAD_SIZES[@]}"; do
        total_size=$(( total_size + UPLOAD_SIZES[i] ))
        upload_sec=$(( upload_sec + UPLOAD_SECS[i] ))
    done

    section "备份报告"
    say ""
    printf '  %-12s %s\n' "任务" "$VMIDS"
    printf '  %-12s %s\n' "开始时间" "$(date -d @$t_start '+%F %T')"
    printf '  %-12s %s\n' "结束时间" "$(date -d @$t_end '+%F %T')"
    printf '  %-12s %ss (备份 %ss / 上传 %ss)\n' "总耗时" "$total_sec" "$backup_sec" "$upload_sec"
    printf '  %-12s %s\n' "归档数量" "${#UPLOAD_NAMES[@]} 个，共 $(hsize "$total_size")"
    printf '  %-12s %s\n' "远端目录" "${RCLONE_REMOTE}:${REMOTE_SUBDIR}"
    printf '  %-12s %s 个，共 %s\n' "远端存量" "$remote_count" "$(hsize "$remote_bytes")"
    printf '  %-12s %s 个，共 %s\n' "本地存量" "$local_count" "$(hsize "${local_bytes:-0}")"
    printf '  %-12s %s\n' "保留策略" "本地 $LOCAL_PRUNE / 远端 ${REMOTE_RETENTION:-不清理}"
    printf '  %-12s %s\n' "清理结果" "$retention_msg"
    say ""
    printf '  %s %10s %6s %s\n' "$(pad '文件' 46)" "大小" "耗时" "结果"
    for i in "${!UPLOAD_NAMES[@]}"; do
        printf '  %s %10s %5ss %s\n' \
            "$(pad "${UPLOAD_NAMES[i]}" 46)" "$(hsize "${UPLOAD_SIZES[i]}")" \
            "${UPLOAD_SECS[i]}" "${UPLOAD_RESULTS[i]}"
    done

    say ""
    if [ "$fail" -eq 0 ]; then
        say "  状态: ✅ 成功"
        section "结束 $(date '+%F %T')"
        return 0
    fi

    say "  状态: ❌ 存在失败（可执行 '$0 upload' 重试上传）"
    section "结束 $(date '+%F %T')"
    [ "$UPLOAD_FAILURE_FATAL" = "1" ] && return 1
    return 0
}

# ---------------- 仅上传 ----------------
cmd_upload() {
    need_root
    LOGGING=1
    load_conf

    exec 9>"$LOCK"
    flock -w 3600 9 || die "等待运行锁超时，已有实例在运行"
    have_rclone_remote || die "rclone remote '${RCLONE_REMOTE}' 不存在"

    section "仅上传模式：扫描 $DUMPDIR"
    say "  远端: ${RCLONE_REMOTE}:${REMOTE_SUBDIR}"

    local -a files=()
    mapfile -t files < <(find "$DUMPDIR" -maxdepth 1 -type f \
        -name 'vzdump-*.vma.zst' 2>/dev/null | sort)

    if [ "${#files[@]}" -eq 0 ]; then
        say "  本地没有备份文件"
        return 0
    fi

    local fail=0 f
    for f in "${files[@]}"; do
        upload_file "$f" || fail=1
    done

    if [ -n "$REMOTE_RETENTION" ]; then
        rclone delete "${RCLONE_REMOTE}:${REMOTE_SUBDIR}" \
            --config "$RCLONE_CONFIG" \
            --min-age "$REMOTE_RETENTION" \
            --include "vzdump-*.vma.*" \
            --log-level INFO 2>&1 | tee -a "$LOG"
    fi

    if [ "$fail" -eq 0 ]; then
        say "  结果: ✅ 全部就绪"
        return 0
    fi
    say "  结果: ❌ 部分上传失败"
    return 1
}

# ---------------- 安装/注册 ----------------
write_config() {
    umask 022
    cat > "$CONF" <<EOF
# 由 $SELF_PATH install 生成 $(date '+%F %T')
VMIDS="$VMIDS"
STORAGE="$STORAGE"
BACKUP_MODE="$BACKUP_MODE"
COMPRESS="$COMPRESS"
LOCAL_PRUNE="$LOCAL_PRUNE"
DUMPDIR="$DUMPDIR"
RCLONE_REMOTE="$RCLONE_REMOTE"
REMOTE_SUBDIR="$REMOTE_SUBDIR"
REMOTE_RETENTION="$REMOTE_RETENTION"
DELETE_LOCAL=$DELETE_LOCAL
VERIFY_HASH=$VERIFY_HASH
UPLOAD_FAILURE_FATAL=$UPLOAD_FAILURE_FATAL
SCHEDULE="$SCHEDULE"
RCLONE_RETRIES=$RCLONE_RETRIES
RCLONE_TIMEOUT="$RCLONE_TIMEOUT"
EOF
    chmod 644 "$CONF"
}

write_units() {
    cat > "$UNIT_DIR/$SERVICE_NAME" <<EOF
[Unit]
Description=PVE backup + WebDAV upload
Wants=network-online.target
After=network-online.target pve-cluster.service pvestatd.service

[Service]
Type=oneshot
ExecStart=$SELF_PATH run
TimeoutStartSec=0
Nice=10
IOSchedulingClass=best-effort
IOSchedulingPriority=7
EOF

    cat > "$UNIT_DIR/$TIMER_NAME" <<EOF
[Unit]
Description=Daily PVE backup + WebDAV upload

[Timer]
OnCalendar=$SCHEDULE
Persistent=true
AccuracySec=1min
Unit=$SERVICE_NAME

[Install]
WantedBy=timers.target
EOF
}

write_logrotate() {
    cat > "$LOGROTATE_FILE" <<EOF
$LOG {
    weekly
    rotate 8
    missingok
    notifempty
    compress
    copytruncate
    su root root
}
EOF
}

cmd_install() {
    need_root
    LOGGING=1
    load_conf

    local opt_url="" opt_user="" opt_pass="" opt_time="" opt_force=0 opt_no_timer=0

    while [ $# -gt 0 ]; do
        case "$1" in
            --vmid)        VMIDS="$2"; shift 2 ;;
            --storage)     STORAGE="$2"; shift 2 ;;
            --mode)        BACKUP_MODE="$2"; shift 2 ;;
            --compress)    COMPRESS="$2"; shift 2 ;;
            --prune)       LOCAL_PRUNE="$2"; shift 2 ;;
            --time)        opt_time="$2"; shift 2 ;;
            --remote)      RCLONE_REMOTE="$2"; shift 2 ;;
            --subdir)      REMOTE_SUBDIR="$2"; shift 2 ;;
            --retention)   REMOTE_RETENTION="$2"; shift 2 ;;
            --delete-local) DELETE_LOCAL=1; shift ;;
            --verify-hash)  VERIFY_HASH=1; shift ;;
            --url)         opt_url="$2"; shift 2 ;;
            --user)        opt_user="$2"; shift 2 ;;
            --pass)        opt_pass="$2"; shift 2 ;;
            --rclone-conf) RCLONE_CONFIG="$2"; shift 2 ;;
            --force)       opt_force=1; shift ;;
            --no-timer)    opt_no_timer=1; shift ;;
            -h|--help)     cmd_help; exit 0 ;;
            *)             die "install: 未知参数 $1" ;;
        esac
    done

    [ -n "$opt_time" ] && SCHEDULE="$opt_time"

    section "自动注册 PVE 备份服务"

    # 1. 安装自身
    if [ "$(readlink -f "$0")" != "$SELF_PATH" ]; then
        install -m 0755 "$0" "$SELF_PATH"
        say "  [1/6] 已安装脚本: $SELF_PATH"
    else
        chmod 0755 "$SELF_PATH"
        say "  [1/6] 脚本已就位: $SELF_PATH"
    fi

    # 2. rclone remote
    if [ -n "$opt_url" ]; then
        [ -n "$opt_user" ] || die "--url 需要同时提供 --user"
        local obscured
        obscured=$(rclone obscure "$opt_pass" 2>/dev/null)
        if rclone config create "$RCLONE_REMOTE" webdav \
                url="$opt_url" vendor=other user="$opt_user" pass="$obscured" \
                --config "$RCLONE_CONFIG" >/dev/null 2>&1; then
            say "  [2/6] 已注册 rclone remote: $RCLONE_REMOTE -> $opt_url"
        else
            die "创建 rclone remote 失败"
        fi
    elif have_rclone_remote; then
        say "  [2/6] rclone remote 已存在: $RCLONE_REMOTE"
    else
        say "  [2/6] 警告: rclone remote '$RCLONE_REMOTE' 不存在（可稍后用 --url/--user/--pass 注册）"
    fi

    # 3. 配置文件
    if [ -f "$CONF" ] && [ "$opt_force" -eq 0 ]; then
        say "  [3/6] 配置已存在，保留: $CONF（--force 覆盖）"
    else
        write_config
        say "  [3/6] 已写入配置: $CONF"
    fi

    # 4. systemd 单元
    write_units
    systemctl daemon-reload
    say "  [4/6] 已生成 systemd 单元: $SERVICE_NAME / $TIMER_NAME"

    # 5. 日志轮转
    write_logrotate
    say "  [5/6] 已生成日志轮转: $LOGROTATE_FILE"

    # 6. 启用定时器
    if [ "$opt_no_timer" -eq 1 ]; then
        systemctl disable --now "$TIMER_NAME" >/dev/null 2>&1
        say "  [6/6] 已按 --no-timer 跳过定时器启用"
    else
        systemctl enable --now "$TIMER_NAME" >/dev/null 2>&1
        say "  [6/6] 已启用定时器: $TIMER_NAME ($SCHEDULE)"
    fi

    section "注册完成"
    say "  脚本     : $SELF_PATH"
    say "  配置     : $CONF"
    say "  服务     : $SERVICE_NAME"
    say "  定时器   : $TIMER_NAME"
    say "  日志     : $LOG"
    say ""
    say "  立即执行一次 : systemctl start $SERVICE_NAME"
    say "  查看状态     : $SELF_PATH status"
    say "  查看明细     : $SELF_PATH list"
    say "  补传未上传   : $SELF_PATH upload"
}

cmd_uninstall() {
    need_root
    LOGGING=1
    section "注销 PVE 备份服务"
    systemctl disable --now "$TIMER_NAME" >/dev/null 2>&1
    rm -f "$UNIT_DIR/$SERVICE_NAME" "$UNIT_DIR/$TIMER_NAME" "$LOGROTATE_FILE"
    systemctl daemon-reload
    say "  已移除 systemd 单元与日志轮转"
    say "  保留: $CONF / $SELF_PATH / 备份文件（如需彻底清除请手动删除）"
}

# ---------------- 状态/列表 ----------------
retention_desc() {
    local v="$1"
    case "$v" in
        "")            echo "不自动清理" ;;
        *d)            echo "${v%d} 天" ;;
        *w)            echo "$(( ${v%w} * 7 )) 天" ;;
        *)             echo "$v" ;;
    esac
}

print_scope() {
    local qemu lxc
    qemu=$(pvesh get /nodes/pve/qemu --output-format json 2>/dev/null || echo '[]')
    lxc=$(pvesh get /nodes/pve/lxc --output-format json 2>/dev/null || echo '[]')

    python3 - "$VMIDS" "$qemu" "$lxc" <<'PY'
import sys, json, unicodedata

scope, qemu_raw, lxc_raw = sys.argv[1], sys.argv[2], sys.argv[3]
ids = None if scope.strip().lower() == "all" else set(scope.split())

def pad(s, w):
    s = str(s)
    d = sum(2 if unicodedata.east_asian_width(c) in "WF" else 1 for c in s)
    return s + " " * max(0, w - d)

rows = []
for kind, raw in (("qemu", qemu_raw), ("lxc", lxc_raw)):
    try:
        items = json.loads(raw or "[]")
    except Exception:
        items = []
    for it in items:
        vmid = str(it.get("vmid", ""))
        if ids is not None and vmid not in ids:
            continue
        rows.append((vmid, it.get("name", "-"), kind,
                     it.get("status", "-"), float(it.get("maxdisk", 0))))

rows.sort(key=lambda r: int(r[0]) if r[0].isdigit() else 0)
print("  " + pad("VMID", 7) + pad("名称", 24) + pad("类型", 8) + pad("状态", 10) + "磁盘")
if not rows:
    print("  (没有匹配的虚拟机)")
for r in rows:
    print("  " + pad(r[0], 7) + pad(r[1], 24) + pad(r[2], 8) +
          pad(r[3], 10) + ("%.1f GiB" % (r[4] / 1024**3) if r[4] else "-"))
PY
}

cmd_status() {
    load_conf
    LOGGING=0

    local enabled active next result last_start last_rc
    enabled=$(systemctl is-enabled "$TIMER_NAME" 2>/dev/null || echo "disabled")
    active=$(systemctl is-active "$TIMER_NAME" 2>/dev/null || echo "inactive")
    next=$(systemctl show "$TIMER_NAME" -p NextElapseUSecRealtime --value 2>/dev/null)
    result=$(systemctl show -p Result --value "$SERVICE_NAME" 2>/dev/null); result=${result:-unknown}
    last_start=$(systemctl show -p ExecMainStartTimestamp --value "$SERVICE_NAME" 2>/dev/null)
    last_rc=$(systemctl show -p ExecMainStatus --value "$SERVICE_NAME" 2>/dev/null); last_rc=${last_rc:--}
    [ -z "$last_start" ] && last_start="(尚未通过 systemd 执行)"

    section "PVE 自动备份状态"
    if [ "$enabled" = "enabled" ] && [ "$active" = "active" ]; then
        row "自动备份" "✅ 已启用（$TIMER_NAME）"
    elif [ "$enabled" = "enabled" ]; then
        row "自动备份" "⚠️ 已注册但定时器未运行（$active）"
    else
        row "自动备份" "❌ 未启用"
    fi
    row "执行计划" "每天 $SCHEDULE"
    row "下次执行" "${next:-未知}"
    printf '  %s %s（退出码 %s）\n' "$(pad '上次执行' 10)" "$last_start" "$last_rc"
    row "结果" "$result"
    row "脚本" "$SELF_PATH"
    row "配置" "$CONF"

    section "自动备份范围"
    if [ "$VMIDS" = "all" ]; then
        say "  已配置: 全部虚拟机/容器"
    else
        say "  已配置: VMID $VMIDS"
    fi
    print_scope

    section "保留策略"
    local lc lb rc rb
    lc=$(find "$DUMPDIR" -maxdepth 1 -type f -name 'vzdump-*.vma.zst' 2>/dev/null | wc -l)
    lb=$(du -cb "$DUMPDIR"/vzdump-*.vma.zst 2>/dev/null | tail -1 | awk '{print $1}')

    row "本机保留" "$LOCAL_PRUNE（当前 $lc 份 / $(hsize "${lb:-0}")）"

    if have_rclone_remote; then
        rc=$(rclone lsf "${RCLONE_REMOTE}:${REMOTE_SUBDIR}" --config "$RCLONE_CONFIG" \
            --files-only 2>/dev/null | wc -l)
        rb=$(rclone size "${RCLONE_REMOTE}:${REMOTE_SUBDIR}" --config "$RCLONE_CONFIG" \
            --json 2>/dev/null | python3 -c 'import sys,json;print(json.load(sys.stdin).get("bytes",0))' 2>/dev/null || echo 0)
        row "远端保留" "$(retention_desc "$REMOTE_RETENTION")（当前 $rc 份 / $(hsize "${rb:-0}")）"
    else
        row "远端保留" "$(retention_desc "$REMOTE_RETENTION")（remote 不可用）"
    fi

    if [ "$DELETE_LOCAL" = "1" ]; then
        row "本地副本" "上传成功后删除"
    else
        row "本地副本" "保留"
    fi
    if [ "$VERIFY_HASH" = "1" ]; then
        row "完整性校验" "SHA256"
    else
        row "完整性校验" "仅比对大小"
    fi

    section "存储与目标"
    row "本地目录" "$DUMPDIR（存储 $STORAGE）"
    row "远端目标" "${RCLONE_REMOTE}:${REMOTE_SUBDIR}"
    if have_rclone_remote; then
        row "远端连通" "✅ 可访问"
    else
        row "远端连通" "❌ remote '$RCLONE_REMOTE' 不存在"
    fi

    section "最近日志"
    if [ -r "$LOG" ]; then
        tail -n 6 "$LOG" | sed 's/^/  /'
    else
        say "  (暂无日志)"
    fi
    say ""
}

cmd_list() {
    load_conf
    LOGGING=0
    section "本地备份 ($DUMPDIR)"
    if ls "$DUMPDIR"/vzdump-*.vma.zst >/dev/null 2>&1; then
        printf '  %s %10s  %s\n' "$(pad '文件' 46)" "大小" "时间"
        local f
        for f in "$DUMPDIR"/vzdump-*.vma.zst; do
            printf '  %s %10s  %s\n' "$(pad "$(basename "$f")" 46)" \
                "$(hsize "$(stat -c %s "$f")")" \
                "$(date -r "$f" '+%F %T')"
        done
    else
        say "  (无)"
    fi

    section "远端备份 (${RCLONE_REMOTE}:${REMOTE_SUBDIR})"
    if have_rclone_remote; then
        rclone lsl "${RCLONE_REMOTE}:${REMOTE_SUBDIR}" --config "$RCLONE_CONFIG" 2>&1 \
            | awk '{printf "  %10s  %s %s  %s\n", $1, $2, $3, $4}' || true
    else
        say "  remote '$RCLONE_REMOTE' 不可用"
    fi
}

cmd_config() {
    load_conf
    LOGGING=0
    section "当前配置 ($CONF)"
    printf '  %-20s %s\n' "VMIDS" "$VMIDS"
    printf '  %-20s %s\n' "STORAGE" "$STORAGE"
    printf '  %-20s %s\n' "BACKUP_MODE" "$BACKUP_MODE"
    printf '  %-20s %s\n' "COMPRESS" "$COMPRESS"
    printf '  %-20s %s\n' "LOCAL_PRUNE" "$LOCAL_PRUNE"
    printf '  %-20s %s\n' "DUMPDIR" "$DUMPDIR"
    printf '  %-20s %s\n' "RCLONE_REMOTE" "$RCLONE_REMOTE"
    printf '  %-20s %s\n' "REMOTE_SUBDIR" "$REMOTE_SUBDIR"
    printf '  %-20s %s\n' "REMOTE_RETENTION" "${REMOTE_RETENTION:-<不清理>}"
    printf '  %-20s %s\n' "DELETE_LOCAL" "$DELETE_LOCAL"
    printf '  %-20s %s\n' "VERIFY_HASH" "$VERIFY_HASH"
    printf '  %-20s %s\n' "UPLOAD_FAILURE_FATAL" "$UPLOAD_FAILURE_FATAL"
    printf '  %-20s %s\n' "SCHEDULE" "$SCHEDULE"
}

cmd_help() {
    cat <<'EOF'
pve-backup.sh —— PVE 备份 + WebDAV 上传（单文件自包含）

用法:
  pve-backup.sh                 交互式菜单（无终端时自动显示状态）
  pve-backup.sh menu            交互式菜单
  pve-backup.sh status          查看自动备份状态（不执行备份）
  pve-backup.sh run             执行一次备份 + 上传
  pve-backup.sh upload          只补传本地未上传的备份（幂等）
  pve-backup.sh list            列出本地/远端备份明细
  pve-backup.sh config          打印当前配置
  pve-backup.sh install [参数]  自动注册服务与定时器
  pve-backup.sh uninstall       注销服务与定时器

install 参数:
  --vmid "100 101"   要备份的 VMID，或 all
  --time 02:30       每天执行时间
  --storage local    备份存储
  --mode snapshot    snapshot / suspend / stop
  --compress zstd    zstd / gzip / lzo
  --prune keep-last=3   本机保留策略
  --subdir PATH      远端目录
  --retention 7d     远端保留（留空=不清理）
  --url/--user/--pass   自动注册 rclone WebDAV remote
  --remote NAME      rclone remote 名称（默认 webdav）
  --delete-local     上传成功后删除本地
  --verify-hash      额外做 SHA256 校验
  --force            覆盖已有配置
  --no-timer         只注册服务，不启用定时器
EOF
}

# ---------------- 交互式菜单 ----------------
menu_pause() {
    printf '\n按回车返回...'
    read -r _ || return 1
}

menu_config() {
    while true; do
        section "修改配置"
        say "  1) 备份的虚拟机    : $VMIDS"
        say "  2) 每天执行时间    : $SCHEDULE"
        say "  3) 本机保留策略    : $LOCAL_PRUNE"
        say "  4) 远端保留天数    : ${REMOTE_RETENTION:-<不清理>}"
        say "  5) 上传后删本地    : $DELETE_LOCAL"
        say "  6) SHA256 校验     : $VERIFY_HASH"
        say "  0) 返回"
        say ""
        printf '请选择 [0-6]: '
        local c v
        read -r c || return 0
        case "$c" in
            1)
                printf '输入 VMID（空格分隔，all 表示全部）: '
                read -r v; [ -n "$v" ] && VMIDS="$v"
                write_config; say "已保存 VMIDS=$VMIDS" ;;
            2)
                printf '输入每天执行时间（HH:MM）: '
                read -r v; [ -n "$v" ] && SCHEDULE="$v"
                write_config; write_units; systemctl daemon-reload
                systemctl restart "$TIMER_NAME" >/dev/null 2>&1
                say "已保存并重载定时器: 每天 $SCHEDULE" ;;
            3)
                printf '输入本机保留策略（如 keep-last=3，留空=不限制）: '
                read -r v; LOCAL_PRUNE="$v"
                write_config; say "已保存 LOCAL_PRUNE=${LOCAL_PRUNE:-<不限制>}" ;;
            4)
                printf '输入远端保留天数（如 7d；留空=不清理）: '
                read -r v; REMOTE_RETENTION="$v"
                write_config; say "已保存 REMOTE_RETENTION=${REMOTE_RETENTION:-<不清理>}" ;;
            5)
                [ "$DELETE_LOCAL" = "1" ] && DELETE_LOCAL=0 || DELETE_LOCAL=1
                write_config; say "已保存 DELETE_LOCAL=$DELETE_LOCAL" ;;
            6)
                [ "$VERIFY_HASH" = "1" ] && VERIFY_HASH=0 || VERIFY_HASH=1
                write_config; say "已保存 VERIFY_HASH=$VERIFY_HASH" ;;
            0) return 0 ;;
            *) say "无效选择: $c" ;;
        esac
        menu_pause
    done
}

menu_toggle_timer() {
    section "启用 / 停用自动备份"
    say "  当前定时器: $(systemctl is-active "$TIMER_NAME" 2>/dev/null) / $(systemctl is-enabled "$TIMER_NAME" 2>/dev/null)"
    say ""
    say "  1) 启用"
    say "  2) 停用"
    say "  0) 返回"
    say ""
    printf '请选择 [0-2]: '
    local c
    read -r c || return 0
    case "$c" in
        1) systemctl enable --now "$TIMER_NAME" >/dev/null 2>&1; say "已启用自动备份（每天 $SCHEDULE）" ;;
        2) systemctl disable --now "$TIMER_NAME" >/dev/null 2>&1; say "已停用自动备份（配置保留）" ;;
        0) return 0 ;;
        *) say "无效选择: $c" ;;
    esac
}

menu_uninstall() {
    printf '确认卸载服务与定时器？配置和备份文件会保留 [y/N]: '
    local c
    read -r c || return 0
    case "$c" in
        y|Y) cmd_uninstall ;;
        *)   say "已取消" ;;
    esac
}

cmd_menu() {
    LOGGING=0
    while true; do
        clear 2>/dev/null || true
        section "PVE 备份管理"
        say "  1) 查看自动备份状态"
        say "  2) 立即执行一次备份 + 上传"
        say "  3) 只补传本地未上传的备份"
        say "  4) 查看本地/远端备份明细"
        say "  5) 查看当前配置"
        say "  6) 修改配置"
        say "  7) 启用 / 停用自动备份"
        say "  8) 重新注册服务与定时器"
        say "  9) 卸载服务与定时器"
        say "  0) 退出"
        say ""
        printf '请选择 [0-9]: '
        local c
        read -r c || break
        LOGGING=0
        case "$c" in
            1) cmd_status ;;
            2) cmd_run ;;
            3) cmd_upload ;;
            4) cmd_list ;;
            5) cmd_config ;;
            6) menu_config ;;
            7) menu_toggle_timer ;;
            8) cmd_install --force ;;
            9) menu_uninstall ;;
            0|q|Q) break ;;
            *) say "无效选择: $c" ;;
        esac
        # 释放可能由 run/upload 持有的运行锁，避免菜单会话阻塞定时任务
        flock -u 9 2>/dev/null || true
        exec 9>&- 2>/dev/null || true
        LOGGING=0
        printf '\n按回车返回菜单...'
        read -r _ || break
    done
    say "已退出"
}

# ---------------- 入口 ----------------
cmd="${1:-auto}"
[ $# -gt 0 ] && shift

case "$cmd" in
    auto)
        if [ -t 0 ] && [ -t 1 ]; then
            cmd_menu
        else
            cmd_status
        fi
        ;;
    menu)       cmd_menu ;;
    run)        cmd_run ;;
    upload)     cmd_upload ;;
    install)    cmd_install "$@" ;;
    uninstall)  cmd_uninstall ;;
    status)     cmd_status ;;
    list)       cmd_list ;;
    config)     cmd_config ;;
    help|-h|--help) cmd_help ;;
    *)          die "未知命令: $cmd（可用: menu/run/upload/install/uninstall/status/list/config）" ;;
esac
