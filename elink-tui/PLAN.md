# elink-tui: Linux 终端 TUI 应用 (Rust)

## Context

elink-ai 目前只有 macOS 菜单栏 GUI (mac-app/, Swift) 和树莓派墨水屏 agent (elink-agent/, Python)。Linux 用户没有任何本地界面。目标:新增一个 Rust 编写的键盘驱动 TUI 应用,在 Linux 终端里镜像 mac-app 的核心 dashboard(Claude/Codex 双卡片:状态、今日 token、按模型明细、5h/周配额条与重置倒计时),完全不需要鼠标。

已与用户确认的决策:
- **技术栈: Rust** (ratatui + crossterm)
- **双数据模式**: 本地模式(直接读 Linux 上的 `~/.claude`、`~/.codex` 并调用 provider usage API)+ 远程模式(轮询现有 mac-app bridge `http://host:8765/v1/status`)

v1 范围外:多 Mac 集群同步、墨水屏设备控制、更新检查、历史统计页。

## 移植参照(权威来源,实现时必读)

- `mac-app/Sources/ElinkAIBridge/StatusService.swift` — JSONL 会话解析、token 去重/增量规则、活跃状态阈值 (mtime <20s=working, <30min=idle, 否则 offline;第 584-589 行)
- `mac-app/Sources/ElinkAIBridge/UsageFetcher.swift` — 配额 API、凭据读取、fallback、keep-last-good、节奏 (120s 定时、60s 下限、429 后退避 300s、20s 超时)
- `mac-app/Sources/ElinkAIBridge/Models.swift` — `/v1/status` 字段名与 null 语义(过期窗口置 null,`discardingIfExpired`)
- `fixtures/status-v1.json` — 反序列化测试 fixture(注意:缺 `cluster`/`provider_usage_fetched_at`/`provider_usage_cached`,serde 全部字段需 optional-with-default)
- `docs/protocol.md` — schema 契约。Claude 用 `five_hour_*`/`seven_day_*`,Codex 用 `primary_*`/`weekly_*`;未知值为 null 而非 0
- 轮询节奏参照 `elink-agent/src/elink_agent/config.py`: status 每 2s,超时 3s

## Crate 布局

新顶层目录 `elink-tui/`(与 `mac-app/`、`elink-agent/` 平级):

```
elink-tui/
├── Cargo.toml
├── src/
│   ├── main.rs          # clap 参数、终端 setup/teardown、事件循环
│   ├── config.rs        # CLI 参数 + ~/.config/elink-ai/tui.toml 合并
│   ├── model.rs         # Snapshot/ProviderStatus/UsageWindow/ModelUsage + serde
│   ├── app.rs           # App 状态机: 焦点、模式、help overlay、滚动、按键处理
│   ├── ui.rs            # ratatui 渲染: 布局、provider 卡片、配额 Gauge、帮助层、底部键位栏
│   ├── source/
│   │   ├── mod.rs       # Source 枚举 (Remote|Local)、后台 worker 线程 + mpsc
│   │   ├── remote.rs    # ureq GET /v1/status → model::Snapshot
│   │   └── local/
│   │       ├── mod.rs   # 汇总 sessions + quota 组装 Snapshot
│   │       ├── creds.rs # Claude token (env/文件)、Codex auth.json + JWT claim 解码
│   │       ├── quota.rs # Anthropic + ChatGPT usage API、statusline 缓存 fallback、keep-last-good、退避
│   │       └── sessions.rs # JSONL 扫描: Claude 去重求和、Codex 增量、按天分桶、mtime 状态
│   └── util.rs          # ~ 展开、ISO8601 解析、格式化
└── tests/
    ├── fixtures/        # claude/codex 会话 JSONL、usage API 响应、auth.json 样例
    └── status_schema.rs # include_str! 反序列化 ../../fixtures/status-v1.json
```

并发模型:每个激活 source 一个后台线程,经 `std::sync::mpsc` 把 `Snapshot`/错误发给 UI 循环;UI 循环 `crossterm::event::poll` + ~100ms tick 刷新倒计时。**不用 async runtime**。

## 依赖(最小集)

`ratatui` + `crossterm`、`serde`/`serde_json`、`ureq`(rustls;阻塞式,每周期最多 3 个小 GET,拒绝 tokio/reqwest 的额外依赖)、`toml`、`chrono`(ISO8601 + 本地时区按天分桶)、`base64`(JWT payload 解码,不引 JWT 库)、`clap`(derive)、`dirs`、`anyhow`。

## 模式与配置

```
elink-tui                          # 本地模式(默认)
elink-tui --bridge http://mac:8765 # 远程模式
elink-tui --config PATH
elink-tui --once                   # 采集一次快照打印 JSON 后退出(调试/CI)
```

配置文件 `~/.config/elink-ai/tui.toml`(CLI 覆盖文件,全部可选):
`mode`、`bridge_url`、`[refresh] status_poll_s=2 / quota_fetch_s=120`、`[paths] claude_home / codex_home / statusline_cache`(测试用覆盖)。

本地模式要点(忠实移植 Swift 逻辑):
- Claude token: env `CLAUDE_CODE_OAUTH_TOKEN` → `~/.claude/.credentials.json` 的 `claudeAiOauth.accessToken`(Linux 无 Keychain 路径)
- Claude 配额: `GET https://api.anthropic.com/api/oauth/usage`,头 `Authorization: Bearer` + `anthropic-beta: oauth-2025-04-20`;失败时 fallback `~/.cache/statusline/last.json`(6 小时内有效,标记 cached)
- Codex 配额: `GET https://chatgpt.com/backend-api/wham/usage`,Bearer + `ChatGPT-Account-Id`;凭据 `~/.codex/auth.json`,account id 取 `tokens.account_id` 或解 `tokens.id_token` JWT claim;`limit_window_seconds >= 518400` ⇒ weekly;再 fallback 会话日志里最新 `payload.rate_limits`
- keep-last-good: 拉取失败保留上次非空窗口并标记 cached;`reset_at` 已过则丢弃置 null
- 会话扫描: Claude 递归 `~/.claude/projects/**/*.jsonl`,4 字段 token 求和,按 `message.id`/`uuid` 去重取 max,本地时区按天分桶,按 `message.model` 分组;Codex 递归 `~/.codex/sessions`,`payload.type=="token_count"`,优先 `last_token_usage.total_tokens`,否则累计值差分
- `needs_input` 本地模式 v1 恒为 false(Mac 上靠 hook 事件;后续可加监听),状态仅由 mtime 推导

## 键盘快捷键

| 键 | 动作 |
|---|---|
| `q` / `Ctrl-C` | 退出(恢复终端) |
| `r` | 手动刷新: 强制配额拉取 + 立即重扫/轮询 |
| `Tab`、`←`/`→`、`h`/`l` | 切换焦点卡片 |
| `1` / `2` | 直达 Claude / Codex |
| `↑`/`↓`、`k`/`j` | 焦点卡片内滚动模型列表 |
| `m` | 本地 ↔ 远程模式切换(未配 bridge_url 时底部提示) |
| `?` | 帮助浮层;`Esc` 关闭 |

底部常驻单行键位栏。

## UI 布局 (80×24)

```
┌ elink-ai ── local ── updated 1s ago ── quota fetched 47s ago ────────────────┐
│┌ Claude ──────────────── ● working ┐┌ Codex ───────────── ○ idle  ⚠ input ┐│
││ Tokens today      4,868,001       ││ Tokens today          61,471        ││
││  claude-sonnet-4-5    3,211,000   ││  gpt-5.6-terra          42,100      ││
││  claude-opus-4-1      1,657,001   ││  gpt-5.6-luna           19,371      ││
││ 5h    [██████████░░░░░░░░░]  43%  ││ 5h    [███░░░░░░░░░░░░░░░]  12%     ││
││       resets in 1h 27m            ││       resets in 2h 24m              ││
││ 7d    [█████████████░░░░░░]  68%  ││ Week  [████░░░░░░░░░░░░░░]  22%     ││
││       resets in 3d 0h             ││       resets in 6d 1h  (cached)     ││
│└───────────────────────────────────┘└─────────────────────────────────────┘│
│ q quit  r refresh  ⇥ focus  m mode  ? help                                  │
└──────────────────────────────────────────────────────────────────────────────┘
```

- ≥70 列左右分栏,<70 列上下堆叠;焦点卡片高亮边框
- working=绿 / idle=黄 / offline=灰;`needs_input` 反色标签;未知配额显示 `—` 绝不显示 0;provider error 红色截断行;远程连接失败显示全宽 banner 并将 last-good 数据变暗

## 测试

解析逻辑全部写成纯函数,无需网络:
- `tests/status_schema.rs`: 反序列化仓库 `fixtures/status-v1.json`,断言缺省字段回退正常;再补一个全字段(含 null、cluster)用例
- sessions 单测: Claude 去重取 max、4 字段求和、按天分桶;Codex 差分规则(首行取累计、累计不变⇒0、优先 last_token_usage)
- quota 单测: Anthropic/wham 响应解析、≥6 天判 weekly、statusline 缓存 6 小时规则、过期窗口丢弃、keep-last-good
- creds 单测: 手工构造的 JWT base64url 解码
- 端到端(无 Mac): `elink-tui --once` 对着 `python3 -m http.server` 伺服的 fixture 验证
- `cargo test` 成为第三套测试;首个 PR 顺带在根 CLAUDE.md 的测试要求里加一句 Rust 测试

## 里程碑(每步独立可验证)

1. **M0 脚手架 + schema**: crate 可编译;`model.rs` 通过 fixture 反序列化测试;`--once --bridge URL` 打印解析结果 → 验证: `cargo test` + fixture server
2. **M1 远程模式 dashboard**: 完整 TUI 循环、2s 轮询、卡片/Gauge/倒计时、键位、帮助层、断连 banner → 验证: 对真实 mac-app bridge 和 fixture server 各跑一次
3. **M2 本地会话扫描**: sessions.rs 移植(只扫 mtime ≥ 当日零点的文件,按 (path, mtime, len) 做解析缓存)、mtime 状态推导 → 验证: 单测 + 在有 `~/.claude`/`~/.codex` 的机器上与 mac-app 数字对账
4. **M3 本地配额**: creds/quota + 各 fallback + keep-last-good + 120s/60s/429 节奏 + `r` 强制刷新 → 验证: 单测 + 实跑;临时破坏凭据观察错误行
5. **M4 收尾**: `m` 模式切换、配置文件、窄屏堆叠、`--once` 输出定稿、README 章节、CHANGELOG 条目;可选 `ubuntu-latest` Rust CI job(现有 macOS 自托管 CI/Release 工作流不动、不受 Rust 门禁影响)

## 风险

- Codex 增量/subagent 归因与 mac-app "usageParserVersion 2" 语义需保持一致,fixture 镜像 + 注释标注 parity
- 大 JSONL 文件扫描成本:M2 的按 (mtime, size) 解析缓存兜底;字节偏移增量 tail 仅在需要时再做(Claude 去重跨行,需缓存 per-file 累加器状态而非仅总数)
- 安全:绝不打印/渲染 token,错误信息不得包含 Authorization 头
- macOS Release 工作流保持不变;Rust 构建不进入其门禁

## 与 mac-app 的功能差距(v1 完成后盘点,2026-07-18)

v1 已对齐 mac-app 的核心 dashboard:双卡片(状态徽章、今日 token、按模型明细、
5h/周配额条与重置倒计时、错误行)、本地会话扫描与配额抓取(含 statusline 缓存、
Codex 日志配额、keep-last-good 全部 fallback)、远程 bridge 轮询、`r` 手动刷新、
断连 banner 保留 last-good。以下是尚未实现的部分,按建议优先级排列。

### 功能性差距(Linux 上有意义,可作为后续迭代)

1. ~~**本地模式 `needs_input` / hook 事件**~~ **已实现(2026-07-19)**:
   `src/source/local/hooks.rs` 内嵌迷你 HTTP 监听(默认 `127.0.0.1:8765`,
   `[hooks] listen` 可改/置空禁用),接受与 mac-app bridge 相同的
   `POST /v1/event`,完整移植 `recordEvent`/`overlay` 语义(5 分钟注意标志、
   10 分钟 working 覆盖、60 秒 idle 降级),现有 `hooks/` 脚本无需改动。
2. ~~**配额缓存跨重启持久化**~~ **已实现(2026-07-19)**:
   `src/source/local/store.rs` 序列化到 `~/.local/state/elink-ai/quota.json`
   (目录 0700 / 文件 0600),读取时按 mac-app 语义丢弃过期窗口、无 reset
   时间超 6 小时不信任;空结果不覆盖、旧观察不回写。同批把配额抓取挪到
   独立线程(`fetching` 防重入),worker 轮询不再被慢网络阻塞。
3. ~~**用量历史统计页**~~ **已实现(2026-07-19,轻量版)**:
   `src/source/local/history.rs` 按天分桶落盘
   `~/.local/state/elink-ai/history.json`(366 天保留,30 秒节流写盘),
   启动后后台线程从现有会话日志回填近一年;`s` 键统计页按 `w`/`m`/`y` 切
   周(柱状)/月(sparkline)/年(按月柱状),含区间总量与按模型明细。未移植
   时区迁移/残差守恒机制(mac-app `runUsageMaintenance`),历史桶固定用本机
   当前时区。
4. ~~**作为数据源服务端**~~ **已实现(2026-07-19)**:hook 监听端点同时伺服
   `GET /v1/status`(bridge 线格式,`Serialize for Snapshot` 输出
   `five_hour_*`/`primary_*` 字段名),已用 `elink_agent.models.StatusSnapshot`
   实际解析验证互通;`[hooks] listen = "0.0.0.0:8765"` 即可供局域网内
   Pi agent 使用。注意:与 mac-app 不同,cluster 字段为 null(v1 客户端可
   忽略),且不提供 `/v2/cluster/*`。
5. ~~**菜单栏常驻用量提示的等价物**~~ **已实现(2026-07-19)**:
   `ui::terminal_title` 用 `crossterm::SetTitle` 把两家中更高的周用量百分比
   写入终端标题(仅在变化时更新);`--compact` 打印单行摘要
   (`C● 43%/68% | X○ 12%/22%`,状态符号 + 主/周百分比 + `⚠` 注意标志)供
   tmux status-line / waybar 用,与 `--once` 互斥。
6. ~~**设备(e-paper)控制**~~ **已实现(2026-07-19)**:
   `src/device.rs` 后台线程轮询 Pi agent `:8766` 的 `/v1/device` 与
   `/v1/preview.png`(仅在设备页打开时轮询),`d` 键设备页用半格块字符
   (`▀` + fg/bg 双像素)按面板宽高比渲染真实墨水屏帧;键位:`1`/`2`/`3`
   切显示模式、`p`/`f` 智能/完整刷新、`b` 把设备的 bridge 指向本机
   (用 UDP connect 探测本机到设备路由上的出口 IP + 监听端口)。
   `[device] url` 配置启用。PNG 用 `png` crate 解码,归一化到 8-bit 灰度。
7. **多 Mac / 多节点集群同步**(参照 `ClusterManager` + protocol.md v2):配对、
   AES-GCM/HMAC 加密快照交换、聚合求和与 freshest-wins 配额。工程量最大,
   **有意保留不做**;远程模式下 TUI 已能显示 bridge 聚合后的集群总和
   (header 的 cluster n/n),短期依赖该路径而不移植 v2 协议。这是唯一
   仍未实现的差距项。
8. ~~**更新检查**~~ **已实现(2026-07-19)**:`src/update.rs` 后台线程查
   GitHub `/releases`(匿名 API 优先,私有仓库 404 时回退到用户已有的
   `gh auth login` 会话,不复制/持久化 token,对齐 `UpdateChecker`),
   跳过 draft/prerelease 取最高稳定版,SemVer 比较(release 高于同版本 rc),
   `u` 键触发,有新版时 header 显示 `⬆ vX.Y.Z available` 标记。crate 版本
   与仓库发布版本对齐(当前 `0.1.15-rc1`)。

### 平台差异,不移植(macOS 专属或已被替代)

- Keychain 凭据回退与 login-shell 环境提取(Linux 凭据就在
  `~/.claude/.credentials.json`,已覆盖)
- 登录自启(macOS `SMAppService`;Linux 交给用户的 systemd user unit /
  终端复用器,TUI 是前台程序)
- Bonjour 设备发现、DHCP/bridge 自愈(菜单栏 app 的设备运维功能)
- SwiftUI 面板交互细节(悬停提示、动画)与日志文件入口(TUI 无日志文件)
- 时区迁移/历史重建(`runUsageMaintenance`):依赖持久历史库,若第 3 项落地
  再评估是否需要
