# pve-backup

Proxmox VE 多虚拟机备份 + WebDAV 远传工具（单文件 Python，无需额外依赖库）。

它绕过 `vzdump` 钩子，用常驻调度进程自己编排整个流程：**vzdump 备份 → 逐个上传远端 WebDAV → 本地/远端保留策略 → 汇总报告**。

## 特性

- **单文件**：整个程序就是一个 Python 脚本，标准库实现，`install` 时自我注册到 `/usr/local/sbin/pve-backup`
- **常驻调度**：单进程 systemd 服务（不是 timer），错过的时间点不会被成堆补跑；有运行锁防止并发
- **多虚拟机**：每台 VM 可单独设置模式、压缩算法、本机保留、远端保留、是否删本地、是否 SHA256 校验
- **一次备份，多路远传**：`remote_paths` 可填多个远端基础目录，同一份归档顺序上传到全部目标
- **远端按时间分目录**：每次运行一个时间戳目录，配合 `remote_keep` 按「保留最新 N 个目录」清理
- **幂等补传**：`upload` 子命令扫描本地未上传的归档，大小一致则跳过，适合失败后重试
- **交互菜单**：`pve-backup` 无参数启动 curses 菜单（方向键选择）；无终端时自动降级为状态输出
- **自检查**：`status` 展示调度时间、下次执行、远端连通性、虚拟机表与最近日志

## 环境要求

| 项目 | 要求 |
|---|---|
| 系统 | Proxmox VE 8.x / 9.x（需要 `vzdump`、`qm`、`pct`） |
| Python | 3.9+（仅标准库；菜单依赖 `curses`，Debian 自带） |
| rclone | 必需，`apt install -y rclone` |
| 权限 | root |

## 快速开始

```bash
git clone https://github.com/xct258/pve-backup.git
cd pve-backup
chmod +x pve-backup

# 注册服务 + 配置虚拟机 + 创建 rclone WebDAV remote
./pve-backup install \
  --vmid 100 101 \
  --url https://dav.example.com/dav \
  --user webdav \
  --pass '你的密码' \
  --subdir 'backup/pve-node1' \
  --mode snapshot \
  --compress zstd \
  --prune keep-last=3 \
  --keep 6

# 查看状态
./pve-backup status

# 立刻跑一次
./pve-backup run
```

`install` 做的事：安装脚本、写入 `/etc/pve-backup.conf`、生成 `/etc/logrotate.d/pve-backup`、生成并启动 `pve-backup.service`、注册 rclone remote（给了 `--url/--user/--pass` 时）。

如果不指定 `--url`，需要事先用 `rclone config` 手动建好名为 `webdav` 的 remote。

## 命令

| 命令 | 说明 |
|---|---|
| `pve-backup` | 交互式菜单（无 TTY 时显示状态） |
| `pve-backup status` | 调度状态、下次执行、远端连通性、VM 表、最近日志 |
| `pve-backup run [vmid]` | 立即备份（省略 vmid 则备份全部已启用虚拟机） |
| `pve-backup upload` | 只补传本地未上传的归档（幂等） |
| `pve-backup list` | 列出本地与远端备份明细 |
| `pve-backup vms` | 列出配置中的虚拟机及参数 |
| `pve-backup add <vmid> [选项]` | 添加虚拟机 |
| `pve-backup edit <vmid> [选项]` | 修改虚拟机参数 |
| `pve-backup remove <vmid>` | 从配置移除虚拟机（不删备份文件） |
| `pve-backup config` | 打印当前配置 |
| `pve-backup install [选项]` | 注册/更新服务 |
| `pve-backup reset` | 清空调度状态并重启服务 |
| `pve-backup uninstall` | 卸载服务（保留配置和备份） |
| `pve-backup daemon` | 前台运行调度进程（systemd 使用） |

单台虚拟机可用选项：`--mode snapshot|suspend|stop`、`--compress zstd|gzip|lzo|0`、`--prune keep-last=N`、`--delete-local` / `--keep-local`、`--verify-hash` / `--no-verify-hash`、`--enable` / `--disable`。

## 配置

配置文件 `/etc/pve-backup.conf`（INI 格式，示例见 [examples/pve-backup.conf.example](examples/pve-backup.conf.example)）：

```ini
[global]
storage = local                 # PVE 存储 ID（备份落在该存储的 dump 目录）
dumpdir = /var/lib/vz/dump      # 与 storage 对应的本地目录
mode = snapshot                 # snapshot / suspend / stop
compress = zstd                 # zstd / gzip / lzo / 0
local_prune = keep-last=3       # 交给 vzdump --prune-backups
remote = webdav                 # rclone remote 名
host_name = pve-node1           # 远端子目录中的主机标识
remote_paths = cloud/pve-backup, nas/pve-backup
remote_keep = 6                 # 远端保留最新 N 个时间目录
delete_local = 0                # 上传成功后删本地归档
verify_hash = 0                 # 上传后下载远端做 SHA256 校验
schedule = monthly 1 00:00      # 调度时间
auto_enabled = 1                # 自动调度开关
rclone_retries = 5
rclone_timeout = 10m

[vm:100]
enabled = 1
mode = snapshot
compress = zstd
local_prune = keep-last=2
delete_local = 1
```

说明：

- **存储固定为 `local`，调度格式固定支持 `daily / weekly / monthly` 友好写法**，也接受原生 systemd `OnCalendar` 表达式。
- 远端实际路径 = `<remote>:<每条 remote_paths>/<host_name>/<运行时间戳>/`
- `[vm:ID]` 段中留空的字段继承 `[global]`。
- 旧的 shell 版配置（`STORAGE=...` 形式）会被自动迁移。

## 调度时间格式

| 写法 | 含义 |
|---|---|
| `daily 02:30` | 每天 02:30 |
| `weekly sun 03:00` | 每周日 03:00 |
| `monthly 1 00:00` | 每月 1 号 00:00 |
| `*-*-* 04:00:00` | 原样透传给 systemd OnCalendar |

## 目录与文件

| 路径 | 说明 |
|---|---|
| `/usr/local/sbin/pve-backup` | 主程序 |
| `/etc/pve-backup.conf` | 配置 |
| `/etc/systemd/system/pve-backup.service` | 调度服务 |
| `/etc/logrotate.d/pve-backup` | 日志轮转（每周，保留 8 份） |
| `/var/log/pve-backup.log` | 运行日志 |
| `/var/lib/pve-backup/state.json` | 调度状态（上次运行时间） |
| `/run/pve-backup.lock` | 运行锁 |
| `/var/lib/vz/dump` | 本地归档（`vzdump-*.vma.*` / `vzdump-*.tar.*`） |

## 常见问题

**报错「未找到 rclone」**
`apt update && apt install -y rclone`，或使用官方脚本安装。

**远端清理没生效 / 上传 403**
远端 WebDAV（如 OpenList/Alist）需要给账号开启「允许删除」权限，否则 `remote_keep` 清理会失败但不影响备份本体。

**`upload` 会不会重复传？**
不会。逐文件比对远端大小，一致即跳过；`verify_hash=1` 时改为下载远端文件做 SHA256 比对，代价是流量翻倍。

**备份失败后怎么补？**
`pve-backup upload` 会扫描本地归档补齐远端；`run <vmid>` 可单独重跑某台。

**退出码**
`0` 全部成功；`1` 存在备份或上传失败；`2` 参数错误。systemd 服务据此判断失败。

## legacy

`legacy/` 里是早期的 shell 实现（`pve-backup.sh` + WebDAV 上传脚本 + hook 方案），已被单文件版取代，仅作历史参考，不要在生产上再使用。

## License

MIT
