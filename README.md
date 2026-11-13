# pve-backup

Proxmox VE 多虚拟机备份 + WebDAV 远传工具（单文件 Python，无需额外依赖库）。

它绕过 `vzdump` 钩子，用常驻调度进程自己编排整个流程：**vzdump 备份 → 逐个上传远端 WebDAV → 本地/远端保留策略 → 汇总报告**。

## 特性

- **单文件**：整个程序就是一个 Python 脚本，标准库实现，`install` 时自我注册到 `/usr/local/sbin/pve-backup`
- **常驻调度**：单进程 systemd 服务（不是 timer），错过的时间点不会被成堆补跑；有运行锁防止并发
- **多虚拟机**：每台 VM 可单独设置模式、压缩算法、本机保留、远端保留、是否删本地、是否 SHA256 校验
- **一次备份，多路远传**：每个远端目录单独配置（`[remote:路径]` 段），同一份归档顺序上传到全部启用目标
- **每个远端独立保留**：每个远端目录可设置不同的保留份数，按「保留最新 N 个时间目录」各自清理
- **幂等补传**：`upload` 子命令扫描本地未上传的归档，大小一致则跳过，适合失败后重试
- **交互菜单**：`pve-backup` 无参数启动全屏仪表盘（顶部实时状态 + 分组菜单 + 内嵌弹层），无终端时自动降级为状态输出
- **自检查**：`status` 展示调度时间、下次执行、远端连通性、虚拟机表与最近日志
- **完成推送**：可选把每次运行结果推送到 [push-server](https://push-server.o1-1.xct258.top)（`POST /api/push`），支持只在失败时推送

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
| `pve-backup` | 全屏仪表盘（无 TTY 时显示状态） |
| `pve-backup status` | 调度状态、下次执行、远端连通性、VM 表、最近日志 |
| `pve-backup run [vmid]` | 立即备份（省略 vmid 则备份全部已启用虚拟机） |
| `pve-backup upload` | 只补传本地未上传的归档（幂等） |
| `pve-backup list` | 列出本地与远端备份明细 |
| `pve-backup vms` | 列出配置中的虚拟机及参数 |
| `pve-backup notify [文本]` | 发送一条测试推送 |
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
remote_keep = 6                 # 新增远端目录时的默认保留数量
delete_local = 0                # 上传成功后删本地归档
verify_hash = 0                 # 上传后下载远端做 SHA256 校验
schedule = monthly 1 00:00      # 调度时间
auto_enabled = 1                # 自动调度开关
rclone_retries = 5
rclone_timeout = 10m

# 推送通知（push-server）
notify_url = https://push-server.o1-1.xct258.top
notify_topic = server/pve-backup
notify_on = always              # always / failure / never
notify_timeout = 10

# 每个远端目录一段，keep 只作用于本目录
[remote:cloud/pve-backup]
keep = 6
enabled = 1

[remote:nas/pve-backup]
keep = 3
enabled = 1

[vm:100]
enabled = 1
mode = snapshot
compress = zstd
local_prune = keep-last=2
delete_local = 1
```

说明：

- **存储固定为 `local`，调度格式固定支持 `daily / weekly / monthly` 友好写法**，也接受原生 systemd `OnCalendar` 表达式。
- 每个远端目录一个 `[remote:路径]` 段，`keep` 只能作用于该目录；`enabled=0` 可临时停用
- 远端实际路径 = `<remote>:<路径>/<host_name>/<运行时间戳>/`
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

## 交互界面

直接运行 `pve-backup`（有 TTY 时）进入全屏仪表盘，顶部实时显示服务与调度状态，菜单按「备份 / 配置 / 系统」分组：

```text
┌─ pve-backup · 备份管理 ──────────────────────────────────────────┐
│ 主机      pve-node1                                              │
│ 自动备份  ✅ 已开启 · 每月 1 号 00:00 · 下次 2026-12-01 00:00     │
│ 调度服务  ● active                                               │
│ 虚拟机    2 台（启用 2）                                         │
│ 远端      webdav → cloud/pve-backup · 保留 6                     │
│ 推送      always · https://push-server.o1-1.xct258.top           │
└──────────────────────────────────────────────────────────────────┘

  备份
   ▸ 立即备份（全部虚拟机）                                   [r]
     补传未上传的备份                                         [u]
     查看备份明细                                             [l]
  配置
     虚拟机管理                                               [v]
     全局参数                                                 [g]
  系统
     运行状态                                                 [s]
     发送测试推送                                             [p]
     服务管理                                                 [m]
     退出                                                     [q]

  就绪
   ↑/↓ 选择   Enter 执行   q 退出
```

按键：

| 按键 | 作用 |
|---|---|
| `↑` `↓` / `j` `k` | 移动选择（自动跳过分组标题） |
| `Enter` | 执行当前项 |
| `r` `u` `l` `v` `g` `s` `p` `m` | 直接跳转对应功能 |
| `q` / `Esc` | 返回上一层 / 退出 |

- 虚拟机管理是一张实时表格（VMID / 名称 / 节点状态 / 启用 / 模式 / 压缩），`a` 添加、`e` 修改、`Space` 启用停用、`d` 移除。
- 全局参数直接改值，输入框支持 `Esc` 取消，调度时间会做格式校验。
- 远端目录在「全局参数 → 远端目录」里增删改，每个目录单独设置保留数量、可临时停用。
- 状态、备份明细、服务操作结果都在内嵌分页视图里滚动查看，不再清屏刷屏。
- 备份/补传这类长任务会临时切回普通终端输出进度，结束按回车回到仪表盘。
- 终端小于 52x16 时显示提示，建议放大窗口。
- 非交互环境（管道、cron、`ssh` 无 TTY）仍然只输出状态文本。

## 推送通知

每次 `run`（含调度触发）结束后，以及每次 `upload` 结束后，可向 push-server 推送一条汇总消息。

| 配置项 | 默认 | 说明 |
|---|---|---|
| `notify_url` | `https://push-server.o1-1.xct258.top` | 推送地址，可写根地址或完整的 `/api/push`；留空关闭 |
| `notify_topic` | `server/pve-backup` | push-server 的 `topic`，用于客户端分类订阅 |
| `notify_on` | `always` | `always` 全部推送 / `failure` 仅失败时推送 / `never` 关闭 |
| `notify_timeout` | `10` | 请求超时（秒） |

对应关系：`server_name` = `host_name`（为空时取系统主机名），`category` = `service`，`title` = `PVE 备份 · <主机>`，`status` = `ok` / `error`，`push_to_mqtt` = `true`，`msg_type` = `markdown`。正文示例：

```markdown
**主机**：pve-node1
**时间**：2026-11-13 02:00:12
**耗时**：312s
**虚拟机**：2 台｜成功 2｜失败 0
**上传**：3.4GiB
**远端**：`cloud/pve-backup/pve-node1/20261113-020003`

| VMID | 名称 | 文件 | 大小 | 结果 |
| --- | --- | --- | --- | --- |
| 100 | web | vzdump-qemu-100-2026_11_13-02_00_03.vma.zst | 2.1GiB | ok |
```

推送失败（网络、超时、服务端 5xx）只会写入日志 `[推送] 发送失败: ...`，不影响备份退出码。验证通道：

```bash
pve-backup notify "测试消息"
```

## 常见问题

**报错「未找到 rclone」**
`apt update && apt install -y rclone`，或使用官方脚本安装。

**远端清理没生效 / 上传 403**
远端 WebDAV（如 OpenList/Alist）需要给账号开启「允许删除」权限，否则按目录保留的清理会失败但不影响备份本体。

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
