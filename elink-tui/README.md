# elink-tui

`elink-tui` 是 [elink-ai](../README.md) 的 Linux 终端界面。它以键盘驱动的
双卡片 Dashboard 展示 Claude Code 和 Codex 的活动状态、今日 Token、按模型
明细、5 小时/周配额与重置倒计时，无需 macOS 菜单栏应用或鼠标。

## 功能

- 同时展示 Claude Code 与 Codex 的 `working`、`idle`、`offline` 状态
- 汇总今日 Token，并按模型展示明细
- 展示 5 小时和周配额、重置倒计时及缓存状态
- 支持本地采集和远程 bridge 两种数据模式
- 提供周、月、年历史用量统计
- 接收 Claude hook 事件，提示权限请求等待状态
- 可作为本地 bridge 向其他客户端提供 `/v1/status`
- 与 mac-app/elink-tui 节点进行端到端加密的用量同步和聚合
- 可选控制 elink-agent 墨水屏设备并预览实际画面
- 提供 JSON 快照和 tmux/waybar 单行摘要

## 环境要求

- Linux
- Rust stable 工具链和 Cargo
- 本地模式下，需要已登录的 Claude Code 和/或 Codex；缺少某一方凭据时，
  另一方的数据仍可正常显示
- 推荐使用支持 Unicode、256 色和较新终端控制序列的终端

Python 3 只在安装可选的 Claude hooks 时需要。GitHub CLI `gh` 只用于更新检查
的认证回退。

## 构建与运行

在 elink-ai 仓库根目录执行：

```bash
cd elink-tui
cargo build --release
./target/release/elink-tui
```

也可以安装到 Cargo 的可执行文件目录：

```bash
cd elink-tui
cargo install --path . --locked
elink-tui
```

GitHub Release 提供 `arm64` Linux 预编译包，文件名为
`elink-tui-vX.Y.Z-linux-arm64.tar.gz`。

## 数据模式

### 本地模式

本地模式是默认模式，不需要 mac-app bridge：

```bash
elink-tui
```

它会读取 `~/.claude` 和 `~/.codex` 下的本地会话记录，并直接向 Anthropic 与
ChatGPT 用量接口查询配额。凭据读取顺序如下：

- Claude：`CLAUDE_CODE_OAUTH_TOKEN`，其次是
  `~/.claude/.credentials.json`
- Codex：`~/.codex/auth.json`

如果配额接口暂时不可用，程序会使用 statusline、Codex 会话日志或上次成功
结果作为回退。今日 Token 和活动状态仍从本地会话记录计算。

### 远程模式

远程模式轮询 macOS bridge 或另一台 elink-tui 提供的 `/v1/status`：

```bash
elink-tui --bridge http://mac:8765
```

也可以在配置文件中设置 `mode = "remote"` 和 `bridge_url`。如果已配置
`bridge_url`，可在 Dashboard 中按 `m` 随时切换本地和远程模式。

远程模式只展示 bridge 返回的数据，不读取或合并当前机器的本地历史记录。

## 命令行参数

```text
elink-tui [OPTIONS] [COMMAND]

--bridge <URL>    使用指定 bridge，并切换为远程模式
--config <PATH>   使用指定配置文件
--once            采集一次，输出格式化 JSON 后退出
--compact         采集一次，输出单行摘要后退出
-h, --help        显示帮助
-V, --version     显示版本

Commands:
cluster           管理加密多节点同步
```

常用示例：

```bash
# 输出本地 JSON 快照；会立即刷新配额
elink-tui --once

# 输出远程 JSON 快照
elink-tui --bridge http://mac:8765 --once

# 输出适合状态栏的单行摘要
elink-tui --compact
```

`--compact` 在本地模式下只扫描当前会话并读取持久化配额缓存，不访问 provider
API、不启动历史回填，也不修改历史文件。输出示例：

```text
C● 43%/68% | X○ 12%/22%
```

其中 `C` 表示 Claude，`X` 表示 Codex；`●`、`○`、`·` 分别表示工作中、
空闲和离线，两个百分比依次为 5 小时和周用量，`-` 表示未知，`⚠` 表示等待
用户输入。

## 配置

默认配置路径为 `~/.config/elink-ai/tui.toml`。配置文件不是必需的，所有字段
均可按需填写：

```toml
mode = "local"                     # "local" 或 "remote"
bridge_url = "http://mac:8765"     # 远程模式及 m 切换使用

[refresh]
status_poll_s = 2                   # 状态轮询间隔，最小 0.5 秒
quota_fetch_s = 120                 # provider 配额刷新间隔，最小 60 秒

[paths]
claude_home = "~/.claude"
codex_home = "~/.codex"
statusline_cache = "~/.cache/statusline/last.json"
usage_db = "~/.local/state/elink-ai/usage.db"

[cluster]
node_name = "linux-workstation"      # 可选，默认为主机名

[hooks]
listen = "127.0.0.1:8765"          # 设为 "" 可关闭监听

[device]
url = "http://pi:8766"             # 配置后启用墨水屏设备页
```

`--config PATH` 可选择另一份配置；`--bridge URL` 会覆盖配置中的 bridge 地址并
强制使用远程模式。配置中存在未知字段或非法值时，程序会直接报告错误。
旧版配置中的 `quota_cache`、`history_cache`、`cluster_state` 仍可保留；它们只
作为旧 JSON 的一次性导入来源，成功导入后以 `usage_db` 为准，原文件不会删除。

## 快捷键

### Dashboard 与统计页

| 按键 | 操作 |
| --- | --- |
| `q` / `Ctrl-C` | 退出并恢复终端 |
| `r` | 立即刷新；本地模式同时强制刷新配额 |
| `Tab` / `Shift-Tab` / `←` / `→` / `h` / `l` | 切换 Claude/Codex 焦点 |
| `1` / `2` | 聚焦 Claude/Codex |
| `↑` / `↓` / `k` / `j` | 滚动当前卡片的模型列表 |
| `s` | 打开或关闭本地/集群聚合历史统计页 |
| `c` | 打开加密集群状态与配对页 |
| `w` / `m` / `y` | 在统计页切换周、月、年范围 |
| `n` | 在统计页轮换全部节点和单个节点；全部节点视图显示各节点占比 |
| `d` | 打开墨水屏设备页 |
| `u` | 检查 GitHub 最新稳定版本 |
| `m` | 在 Dashboard 中切换本地/远程模式 |
| `?` | 打开或关闭帮助 |
| `Esc` | 关闭帮助或返回 Dashboard |

历史统计仅在本地数据模式可用；加入集群后会合并各节点快照，并可按节点筛选。
首次启动后，程序会在后台从现有会话日志回填最近 366 天数据。

### 墨水屏设备页

| 按键 | 操作 |
| --- | --- |
| `1` / `2` / `3` | 切换 dashboard、Claude、Codex 显示模式 |
| `p` / `f` | 请求智能刷新/完整刷新 |
| `b` | 将设备 bridge 指向当前机器 |
| `d` / `Esc` | 返回 Dashboard |

`b` 仅在本地模式、bridge 监听成功、快照足够新且监听地址不是 loopback 时可用。

## Claude hooks 与本地 bridge

默认情况下，程序根据最新会话文件的修改时间推导活动状态：20 秒内为
`working`，30 分钟内为 `idle`，其余为 `offline`。安装 Claude hooks 后，
状态切换和权限请求提示会更及时。

从 elink-ai 仓库根目录执行：

```bash
python3 hooks/install-claude-hooks.py
```

如果当前目录是 `elink-tui/`，可执行：

```bash
(cd .. && python3 hooks/install-claude-hooks.py)
```

安装器会合并而非覆盖现有 Claude hooks，并将原配置备份为
`~/.claude/settings.json.elink-ai.bak`。重启 Claude Code 后生效。Codex hook
格式仍在演进，目前不会自动修改 Codex 配置；Codex 活动状态仍可通过会话文件
判断。

本地模式下的监听器提供：

- `POST /v1/event`：接收 Claude/Codex 生命周期事件
- `GET /v1/status` 或 `GET /`：返回最新的脱敏状态快照
- `GET /v1/health`：健康检查

默认只监听 `127.0.0.1:8765`。如需让局域网内的 elink-agent 或另一台客户端
使用当前机器作为 bridge，可改为：

```toml
[hooks]
listen = "0.0.0.0:8765"
```

监听端口被占用不会使 TUI 退出；程序仍会通过会话文件判断状态，但 hook 和
本地 bridge 服务不可用。

## 加密多节点同步

elink-tui 兼容当前 mac-app 的 v3 安全配对和 v2 同步协议。节点交换按天、provider
和来源节点划分的绝对快照；更高 revision 覆盖旧快照，重复同步不会重复计数。
Dashboard 和历史页会聚合所有节点的 Token，活动状态只统计 90 秒内在线的节点，
配额选择最新且优先无错误的观测结果。

集群操作会修改持久化状态，建议先退出正在运行的 TUI。作为集群首个节点：

```bash
elink-tui cluster create
elink-tui
```

按 `c` 打开集群页，再按 `p` 开放两分钟配对窗口。界面会显示 16 位配对码。
另一节点执行：

```bash
elink-tui cluster join \
  --endpoint http://192.168.1.10:8765 \
  --code ABCD-EFGH-JKMP-QRST
elink-tui
```

参与同步的每个节点都需要让其他节点访问自己的 bridge，因此应在受信任局域网中
配置：

```toml
[hooks]
listen = "0.0.0.0:8765"
```

其他管理命令：

```bash
elink-tui cluster status
elink-tui cluster add-peer --endpoint http://192.168.1.11:8765
elink-tui cluster leave
```

当 `[hooks].listen` 可被局域网访问时，TUI 会用与 mac-app 相同的
`_elink-ai._tcp` mDNS/Bonjour 服务自动发现同一集群节点；VPN、跨网段或 mDNS
不可用时仍可用 `add-peer` 添加固定地址。节点每 15 秒对账一次，本地快照变化
时还会发送 `announce` 触发对端同步。

协议安全机制包括：X25519 临时密钥交换、配对码 HMAC proof、HKDF、
AES-256-GCM、请求时间戳与 nonce 的 HMAC-SHA256 签名，以及重放拒绝。配对码
不会通过网络发送，窗口最多保留两分钟并限制五次尝试。集群身份、共享密钥、
节点和快照保存在共享 `usage.db`，文件权限为 `0600`。

当前协议使用集群共享密钥，不能单独吊销一个节点。需要排除旧节点时，应离开并
重新创建集群，然后重新配对可信节点。加入/离开集群导致时区变化时，程序会在
同一 SQLite 事务中重新分桶；已删除日志留下的不可重建用量按模型守恒保留。

## 墨水屏设备控制

配置 elink-agent 地址后，按 `d` 打开设备页：

```toml
[device]
url = "http://pi:8766"
```

设备页轮询 `/v1/device` 和 `/v1/preview.png`，显示 agent 状态并用终端半格
字符预览实际墨水屏帧。切换显示模式和刷新操作会调用 elink-agent 的控制
接口。

如果希望通过 `b` 把设备指向本机 bridge，需要把 `[hooks].listen` 设置为
局域网可访问地址（通常为 `0.0.0.0:8765`）。程序会自动探测当前机器到设备
所用的出口 IP。

## tmux / waybar

tmux 示例：

```tmux
set -g status-right '#(elink-tui --compact)'
```

Waybar 自定义模块示例：

```json
"custom/elink-ai": {
  "exec": "elink-tui --compact",
  "interval": 15
}
```

## 本地数据与缓存

| 路径 | 用途 |
| --- | --- |
| `~/.claude/projects/**/*.jsonl` | Claude 会话用量与活动状态 |
| `~/.codex/sessions/**` | Codex 会话用量、活动状态及配额回退 |
| `~/.cache/statusline/last.json` | Claude 配额回退 |
| `~/.local/state/elink-ai/usage.db` | 配额缓存、最近 366 天历史、分桶时区、集群凭据/节点/快照，文件权限为 `0600` |

旧版 `quota.json`、`history.json`、`cluster.json` 会在对应 SQLite 表为空时导入；
导入源保留不动，便于恢复。

程序不会通过 `/v1/status` 暴露 OAuth Token 或原始会话日志。配额过期后会被
丢弃，不会作为 `0%` 展示。

## 开发与测试

```bash
cd elink-tui
cargo fmt --check
cargo test
```

协议字段说明见 [HTTP protocol v1](../docs/protocol.md)，实现背景和范围见
[PLAN.md](PLAN.md)。

## 安全说明

elink-tui 的普通 bridge/hook 和 elink-agent 控制接口仍是未认证的明文 HTTP；
集群 v2/v3 payload 自身经过认证加密，但端点地址和流量元数据可见。所有接口都
只应在受信任的本机、局域网或受控 VPN 中使用。不要把 8765 或 8766 端口直接
暴露到公网。

## 许可证

本项目使用 [GPL-3.0-only](../LICENSE) 许可证。
