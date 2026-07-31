# elink-ai 实施计划

## 1. 目标与范围

在当前空仓库中构建一套由 macOS 菜单栏应用和树莓派电子墨水屏服务组成的 AI 用量看板：

- 保留 `../esp8266-ai/mac-app` 的 macOS 原生菜单栏桥接形态，以及 Claude Code / Codex 的本地状态、真实额度和 hooks 数据链路。
- 删除 ESP8266 固件依赖，不再由 Mac 控制或配对 ESP8266。
- 参考 `../InkyPi` 的 PIL 图像处理、Waveshare `epd5in83_V2` 驱动、SPI/GPIO 初始化和 systemd 部署方式，在树莓派上驱动 648×480 单色电子墨水屏。
- 同屏展示 Claude 与 Codex 的工作状态、5 小时额度、周额度、重置时间、今日 token 和待审批提醒。
- 根据数据变化刷新屏幕，同时限制刷新频率、重影和无意义的全刷。

首版不迁移 `esp8266-ai` 的桌宠 GIF、音乐页、网速曲线和 240×240 LCD 动画。这些功能依赖高刷新率和彩色像素，不适合电子墨水屏，也不是本项目的核心目标。Mac 菜单栏的用量显示、设备状态、手动刷新、显示模式和预览能力保留并针对 elink 重做。

## 2. 已确认的参考实现

### esp8266-ai 可复用部分

- `UsageFetcher.swift`：读取 Claude Keychain/凭据文件和 Codex `~/.codex/auth.json`，请求两家的 5h/周额度接口，含缓存和 429 退避。
- `StatusReader.swift`：扫描 Claude/Codex JSONL 会话日志，计算工作状态和今日 token；接收 hooks 事件并识别 `needs_input`。
- `HTTPServer.swift`：使用 Network.framework 提供零第三方依赖的局域网 HTTP 服务。
- `MenuBarController.swift`：菜单栏常驻、左右键交互、用量详情和设备控制入口。
- `DeviceClient.swift`：设备地址持久化、被动发现、地址复验和 `/24` 扫描的整体思路。

需要改造的部分是所有带有 ESP8266、sprite、music、net 和 240×240 镜像假设的接口与 UI。

### InkyPi 可复用部分

- `DisplayManager` 的“PIL 图片 → 方向/尺寸处理 → 具体显示驱动”边界。
- `WaveshareDisplay` 的动态加载和 `getbuffer()` 调用方式。
- `epd5in83_V2.py` 与 `epdconfig.py` 中 648×480 面板、SPI0、GPIO17/25/24、CS0 和 busy 超时处理。
- systemd 服务、依赖安装、SPI 启用和 mock display 的部署/开发思路。

不能直接照搬当前 `WaveshareDisplay.display_image()`：它每次都执行 `init → Clear → display → sleep`，会增加闪烁、刷新耗时和面板损耗。项目需要单独的刷新策略层。

另外，当前 `../InkyPi` 工作区中的 `src/display/waveshare_epd/epd5in83_V2.py` 存在未提交修改，并包含 `init_Fast`、`init_Part` 和 `display_Partial`。实施前要保存差异并在实机上验证，不能把工作区特有行为误当成上游稳定接口。

## 3. 总体架构

```text
Claude/Codex 凭据、会话日志、hooks
                 │
                 ▼
┌──────────────────────────────────┐
│ macOS: ElinkAIBridge (Swift)     │
│ StatusService + UsageFetcher     │
│ 菜单栏 UI + HTTP :8765           │
└───────────────┬──────────────────┘
                │ LAN: GET /v1/status
                │      POST /v1/event（本机 hooks）
                ▼
┌──────────────────────────────────┐
│ Raspberry Pi: elink-agent        │
│ 轮询/缓存 → 变更判断 → PIL 渲染   │
│ HTTP :8766 + 刷新策略 + 显示适配器│
└───────────────┬──────────────────┘
                │ SPI0 + GPIO
                ▼
       Waveshare 5.83" V2 648×480
```

职责约束：

- OAuth token 始终只留在 Mac，树莓派只能取得已聚合的状态和百分比。
- Mac 不直接访问 SPI/GPIO；屏幕驱动及刷新策略完全在树莓派执行。
- 树莓派主动拉取 Mac 状态。这样 Mac 暂时离线时，屏幕仍可保留最后画面并显示数据陈旧状态。
- 树莓派提供设备 API，供菜单栏查询健康状态、切换页面、触发全刷和获取实际预览图。

## 4. 建议目录结构

```text
elink-ai/
├── mac-app/
│   ├── Package.swift
│   ├── Sources/ElinkAIBridge/
│   │   ├── App/
│   │   ├── Status/
│   │   ├── Server/
│   │   └── Device/
│   └── Tests/ElinkAIBridgeTests/
├── elink-agent/
│   ├── pyproject.toml
│   ├── src/elink_agent/
│   │   ├── api.py
│   │   ├── bridge_client.py
│   │   ├── models.py
│   │   ├── refresh_policy.py
│   │   ├── renderer.py
│   │   └── display/
│   │       ├── base.py
│   │       ├── mock.py
│   │       └── waveshare_5in83_v2.py
│   └── tests/
├── install/
│   ├── elink-agent.service
│   ├── install-pi.sh
│   └── config.example.toml
├── docs/
│   ├── protocol.md
│   ├── hardware.md
│   └── development.md
├── LICENSE
└── README.md
```

## 5. 通信协议

所有新接口带 `/v1` 版本前缀，避免继续绑定旧 ESP8266 的隐式协议。

### Mac bridge，默认 `0.0.0.0:8765`

- `GET /v1/status`：Claude/Codex 状态快照；增加 `schema_version`、`generated_at`、`usage_fetched_at` 和 provider 级错误/陈旧标记。
- `GET /v1/health`：bridge 版本和健康状态，不返回凭据。
- `POST /v1/event`：接收本机 Claude/Codex hooks；仅监听事件名、agent 和必要提示文本。

状态字段沿用现有含义：`status`、`tokens_today`、5h/周百分比与重置分钟、`needs_input`。百分比未知时必须为 `null`，不能当作 0%。

### 树莓派设备端，默认 `0.0.0.0:8766`

- `GET /v1/device`：设备类型、分辨率、bridge 地址、最后成功拉取时间、最后刷屏时间、刷新模式、显示模式、错误状态。
- `GET /v1/preview.png`：返回最后一次实际送屏的 648×480 单色 PNG，Mac 弹窗直接展示，避免 Swift/Python 各维护一套布局。
- `POST /v1/display/mode`：`dashboard | claude | codex`。
- `POST /v1/display/refresh`：手动刷新；参数为 `smart | partial | full`。
- `PUT /v1/config/bridge`：设置 Mac bridge 的 `host:port`。

首版按可信局域网模型运行，并明确文档警告。后续若需要跨不可信网络，再增加配对 token；任何接口都不应返回 OAuth token、Keychain 内容或原始会话日志。

## 6. 电子墨水屏页面设计

默认 `dashboard` 页面采用双栏，而不是像 240×240 LCD 那样轮换角色：

- 顶部：标题、Mac/设备连接状态、最后更新时间。
- 左栏 Claude，右栏 Codex。
- 每栏包含：`WORKING / IDLE / OFFLINE`、5h 大号百分比与进度条、周额度、重置倒计时、今日 token。
- `needs_input=true` 时使用粗黑边框和醒目的 `ACTION REQUIRED` 文案；电子墨水屏不模拟红色闪烁。
- 数据未知显示 `—`，数据陈旧显示 `STALE`，不能用旧数据冒充实时数据。
- 只使用黑、白和可选的 1-bit 抖动；主体文字和进度条不使用灰阶，保证清晰度和局部刷新稳定性。

页面先以 648×480 固定画布实现，字体随仓库分发，避免不同树莓派系统字体导致布局漂移。`claude`/`codex` 单页模式可放大额度和状态，用于远距离阅读。

## 7. 刷新策略

“动态展示”定义为高频取数、低频且事件驱动刷屏：

1. `elink-agent` 每 2 秒拉取一次 `/v1/status`，网络请求不等同于刷屏。
2. 对规范化后的可见字段计算 hash；完全相同则不渲染、不刷屏。
3. 普通额度变化按 1 个百分点、重置倒计时按 5 分钟粒度显示，避免每分钟刷新。
4. `working/idle/offline`、`needs_input`、连接断开/恢复是高优先级变化，合并抖动 2–3 秒后尽快刷新。
5. 普通刷新设置最小间隔，建议初始值 30 秒；连续事件只保留最新画面。
6. 优先验证 `init_Part + display_Partial` 的全帧快速波形；累计约 20 次局刷、运行约 6 小时或检测到异常后执行一次完整刷新去重影。
7. 完整刷新不再固定执行额外 `Clear()`；只有首次启动、手动清屏或重影维护时清屏。
8. 所有硬件操作串行化，busy pin 等待有超时；失败后退避重试并保留最后成功画面。

这些数字是安全的初始参数，不是面板最终指标。硬件基线阶段要测量完整刷新、快速刷新耗时与重影，再固化默认值。如果该面板的局刷不稳定，首版退回“仅有意义变化时全刷”，不以可靠性换刷新速度。

## 8. 分阶段实施

### 阶段 0：基线、许可与硬件确认

- 确认树莓派型号、Raspberry Pi OS、Waveshare 5.83" V2 具体版本和接线：SPI0、RST=17、DC=25、BUSY=24、CS0=8。
- 用独立测试图验证白屏、黑屏、完整刷新、快速刷新、局刷、sleep/wake 和 busy 超时。
- 记录 `../InkyPi` 未提交驱动差异，确定哪些修正需要带入。
- 处理代码许可：InkyPi 是 GPL-3.0；`esp8266-ai` 当前仓库没有可见 LICENSE 文件。复制代码前必须确认授权。若无法确认 esp8266-ai 授权，则只参考行为和协议，独立实现对应 Swift 模块。项目 LICENSE 需与实际复用方式兼容。

交付：硬件基线记录、许可决策、最小刷屏脚本和实测刷新参数。

### 阶段 1：仓库骨架与协议

- 创建 Swift package、Python package、统一配置、日志和测试目录。
- 定义版本化 JSON schema、错误码和样例 fixtures。
- 建立 CI：macOS 跑 Swift tests，Linux 跑 Python tests；硬件测试单独标记。

交付：两个进程可启动，health API 和 mock display 可用。

### 阶段 2：迁移 macOS bridge

- 迁移并整理 `UsageFetcher`、`StatusService` 和 hooks 事件状态机。
- 将 HTTP API 改为 `/v1/status`，保留本机 `POST /v1/event`。
- 重做 `DeviceClient`，识别 `device_type=elink-agent`，默认端口改为 8766；保留已配置地址复验、被动发现和 `/24` 扫描兜底。
- 精简菜单：用量详情、设备健康、自动配对、地址设置、页面模式、智能/完整刷新、打开预览、退出。
- 左键 popover 展示设备的 `preview.png` 和连接状态，不再在 Swift 内复刻屏幕渲染器。
- 提供可审查的 hooks 安装/检查脚本；合并用户已有配置，不覆盖其他 hooks。日志 mtime 始终作为兜底。

交付：无实体屏幕时，Mac bridge 可通过 fixtures 和 curl 完整验证。

### 阶段 3：实现树莓派 elink-agent

- 实现 bridge 轮询、超时、指数退避、最后成功快照缓存和开机恢复。
- 实现设备 API、配置持久化和 systemd 健康状态。
- 抽取 InkyPi 驱动所需的最小代码，不引入完整 Flask/插件/playlist 系统。
- 实现 `MockDisplay`，开发机生成 PNG；实现 Waveshare display adapter，隔离 SPI/GPIO。

交付：树莓派能持续取数，mock 和真屏使用同一渲染/刷新入口。

### 阶段 4：渲染器与刷新状态机

- 完成 dashboard/Claude/Codex 三种布局和固定字体。
- 实现规范化 hash、变化优先级、合并刷新、局刷计数和定期全刷。
- 处理未知、陈旧、Mac 离线、额度 API 失败、待审批等状态。
- 每次成功送屏后原子更新 `last-frame.png`，供重启恢复和 Mac 预览。

交付：真实屏幕可稳定动态展示，断网和进程重启不会清成白屏。

### 阶段 5：安装、联调和文档

- 提供 Pi 安装脚本、systemd unit、配置示例、SPI 启用检查和卸载说明。
- 提供 macOS release 构建和 LaunchAgent/登录启动方案，替换参考项目中写死绝对路径的启动脚本。
- 完成首次配对流程、网络变化自愈和端到端故障提示。
- 编写硬件接线、开发调试、API、安全边界和故障排查文档。

交付：从干净系统按 README 可以完成安装、配对、开机自启和实际展示。

## 9. 测试方案

### 自动测试

- Swift：Claude/Codex 凭据 JSON 解析、JWT account id、额度响应、JSONL 日志、hooks TTL、status JSON、设备 API 解析。
- Python：协议模型、陈旧判断、变化分级、刷新节流、全刷周期、断线退避和配置迁移。
- Renderer：固定输入生成 golden PNG，校验尺寸、关键区域和整体 hash。
- Display：mock 断言调用顺序；fake EPD 验证 `init/display/sleep`、超时和异常恢复，不在普通单元测试触碰 GPIO。
- Contract：同一组 JSON fixtures 同时被 Swift 输出测试和 Python 输入测试使用，防止协议两端漂移。

### 实机测试

- 连续运行至少 24 小时，覆盖 Claude/Codex 单独工作、同时工作、空闲和离线。
- 验证 hooks 待审批提醒以及日志兜底。
- Mac 休眠/唤醒、Wi-Fi 切换、树莓派重启、bridge 重启和 API 限流。
- 记录 20 次以上快速刷新后的重影，确认定期全刷能够恢复。
- 断开 busy/GPIO 或模拟超时，确认服务不死锁且不会刷新风暴。

## 10. 验收标准

- Claude 和 Codex 的 5h/周额度与 Mac 菜单栏一致，未知值不会显示为 0%。
- 工作/空闲状态通常在 hook 到达后一次有效屏幕刷新周期内体现；无 hooks 时能由日志自动降级判断。
- 状态不变时不刷屏；普通额度变化不会造成高频刷新；待审批和离线变化有更高优先级。
- Mac 端不向树莓派发送任何 OAuth token 或原始日志。
- 树莓派重启后服务自动恢复；Mac 离线时保留最后有效画面并标记陈旧。
- 菜单栏能够看到设备健康状态、切换页面、触发全刷并查看与实体屏一致的预览。
- 24 小时稳定性测试无 busy 死锁、无限重试、刷新风暴或明显不可恢复重影。

## 11. 主要风险与处理

- **面板局刷能力不确定**：先实测，适配器同时保留 full/fast/partial，失败即退回低频全刷。
- **内部用量接口可能变化**：解析器使用 fixtures、保留最后成功数据并明确错误；接口实现与 UI 解耦。
- **日志格式会演进**：采用容错解析，单条坏记录不能中断快照；hooks 与 mtime 双通道互补。
- **休眠导致 Mac bridge 不可达**：Pi 使用 last-known-good 快照和 stale 状态，不反复清屏。
- **局域网发现不稳定**：手动地址是可靠基线，被动发现和 `/24` 扫描用于改善体验；后续再评估 Bonjour/mDNS。
- **许可证不清晰**：在阶段 0 阻断未经授权的源码复制，必要时按已观察到的行为独立重写 Swift 部分。

## 12. 推荐首个里程碑

先完成一条最短纵向链路：Mac `/v1/status` fixture → Pi 轮询 → 648×480 dashboard PNG → mock display → 真屏完整刷新。确认布局、通信和硬件都成立后，再加入真实额度、hooks、局刷优化和菜单栏设备控制。这样可以最早暴露面板与网络边界问题，同时避免在旧 ESP8266 功能上投入无效迁移成本。

## 13. 规划中：nebula 隧道健康

### 13.1 背景

多主机同步的实际承载网络是一张 nebula overlay。2026-07-28 一次隧道排障（见 `网络杂记/nebula 隧道排障.md`）确认根因是**保端口 NAT 下多个节点争抢外部源端口 4242**：内部端口空闲时原样映射，同一时刻只有一个节点能拿到外部 `:4242`，其余被改写成随机端口且映射很快失效；家庭出口一天重拨三次，每次清空 NAT 映射并重新抢占。修法是给冲突节点分配独占 `listen.port`。

同一次排障还暴露了四类次要故障：host 模式容器把 Docker 网桥地址通告给 lighthouse 拖慢握手（3.99s vs 1.31s）、TUN 模式代理重写 UDP 源端口导致隧道每 23 秒重建（overlay 延迟 246–723ms）、配置写错导致 nebula 静默崩溃重启（累计 1253 次）、以及节点通告不可达 ULA 地址造成日志噪音。

这些问题当时全靠人工登录 lighthouse 跑 `journalctl` 聚合才定位。**目标是让下一次同类故障在客户端上可见，而不是重建一套通用网络监控。**

### 13.2 为什么承载在 elink 客户端

`ClusterManager.syncPeer()` 已经每 15 秒对每个 peer 发一次 `GET /v2/cluster/manifest`，这条请求本身就跑在 overlay 上。因此三项基础设施已经存在：

- **采样已在发生**：只是没有对请求计时，也没有记录失败。
- **可达性判定已存在**：`ClusterNodeRecord.lastSeenAt` 与 `isOnline(90s)`。
- **存储与图表已存在**：`usage.db` 和 TUI `s` 页的日级柱状图组件。

限定：这个 RTT 包含 HMAC 校验与对端处理时间，是**上界而非纯网络 RTT**，不能当作链路指标对外报数。但它测量的是应用层可达性，比 ICMP 更贴近实际影响 —— 排障笔记里「ping 不通不等于隧道不通」（nebula 按需建隧道，前几个包丢在握手期间）正是 ICMP 判据的失效场景。

### 13.3 展示层次

**P0 隧道 RTT 与成功率。** 每 peer 的 p50/p95、15 分钟窗口丢样率、在线/离线跃迁时刻。TUN 代理那类「每 23 秒重建一次」的故障在这张图上表现为明显锯齿。实现上只需在 `syncPeer` 首尾取时间戳、失败也记一条，写入 `usage.db` 新表。

**P1 NAT 外部端口映射。** 这是对本次根因唯一直接有效的指标。端口争抢在延迟图上**看不出来** —— 它表现为某节点整段消失而非变慢。判据取自排障笔记的 STUN 绑定请求：

| 观测 | 结论 |
|---|---|
| 本地端口 == 外部端口 | NAT 保留端口，该节点在争抢池里 |
| 本地端口 != 外部端口 | 不保留，不参与争抢（如经 TUN 代理的节点） |
| 外部 IP 变化 | 一次 WAN 重拨，NAT 映射已清空，预期出现重新抢占 |

一个 UDP 包、无特权、60 秒一次即可。界面上只需一行陈述事实的文案：`223.95.78.14:58682 · 保端口，在争抢池内` 或 `223.95.78.14:65264 · 端口被改写，不参与争抢`，一条就能省掉下一次整晚排查。

**两种结果都不加警示标记。** 本节初稿把 ⚠ 给了「端口被改写」，方向是反的：保端口才是端口争抢的前提条件，被改写的节点反而从不参与争抢（如经 TUN 代理的 Mini-M4）。警示标记只留给判据本身失效，即所有 STUN 服务器都不可达的情况。

**P2 nebula 自身状态（未验证，先确认再决定接入）。** nebula 提供 `stats:` 配置块（prometheus/graphite 导出）与内置 sshd 调试命令，可用于获取握手次数、隧道重建次数和通告地址列表，对应握手耗时与 ULA 噪音两类问题。**具体可用指标尚未在实机确认**，须先在一台 VPS 上验证，不得按假定的指标名编码。

### 13.4 明确不做

- **电子墨水屏不加网络图。** 第 1 节已将网速曲线排除在首版之外，理由是刷新率冲突；本节不推翻该决定。屏幕上最多保留一个字符宽度的降级标志。
- **不使用 ICMP 探测。** DSM 普通用户没有 raw socket 权限（`socket: Operation not permitted`），且 ICMP 结果对 nebula 隧道状态有掩盖性。
- **不引入 Prometheus + Grafana 时序栈。** 这是不到十个节点的自用 mesh，其运维成本高于所解决的问题。
- **不做告警投递。** 展示与历史回溯即可，不引入通知通道。

### 13.5 待决：lighthouse 视角的覆盖方式

本次根因是在 **lighthouse 侧**定位的 —— 只有聚合每个 `certName` 对应的 NAT 源端口分布，才能看出「是谁抢走了 4242」。客户端各自只能观察到「我连不上」，无法归因。

但两台 lighthouse VPS 上没有 Claude/Codex 会话，不是 usage 节点；`elink-tui` 目前也只有交互式 TUI 与 `--once`/`--compact` 一次性输出，没有常驻 daemon 模式。两个方案：

- **A：给 `elink-tui` 增加 headless 模式**，在 VPS 常驻，只做网络采集不做 usage。复用度高，但会把「usage 集群」与「网络拓扑」两个成员集合混同，VPS 将以零 token 节点出现在聚合视图里。
- **B：独立的轻量 exporter 部署在 lighthouse**，把源端口分布推送到 bridge 的新端点。多一个部署单元，但两类数据的节点集合本就不重合。

**已决：选 A（elink-tui headless 模式）。**

A 的已知代价是「VPS 以零 token 节点混进用量聚合」。实现时用一条约束消掉了它：**headless 进程不参与用量集群** —— 不配对、不持有集群密钥、不上报用量，只读取本地 nebula 日志、聚合源端口分布，并在一个独立端口上以只读方式暴露。其他节点主动拉取。因此 usage 集群的成员集合完全不变，13.5 当初担心的两个概念混同并没有发生。

命令是 `elink-tui --headless`，配置在 `[lighthouse]` 段：

```toml
[lighthouse]
journal_unit = "nebula"        # 走 journalctl -u nebula
# log_file = "/var/log/nebula.log"   # 或直接读文件，优先级更高
default_port = 4242
listen = "192.168.100.200:8767"   # 绑 overlay 地址；这份文档不能对公网开放
interval_s = 60
```

日志来源只接受「固定的 journalctl unit 名」或「文件路径」，不接受任意命令，避免把配置文件变成一个执行入口。

### 13.6 分阶段

**阶段 N0：RTT 与可达性**

- `syncPeer` 计时与失败计数；`usage.db` 新增采样表，保留窗口与现有用量历史一致。
- `/v1/status` 的 `cluster` 对象按加性扩展补充 `link` 字段，v1 客户端可忽略（遵循第 5 节的版本化约定）。
- 呈现挂在已有的节点列表上，不新开页面：TUI 的集群页（`c`）在每个节点行追加 `min/avg/max`，mac-app 面板的节点展开项追加一行「同步往返」。RTT 是节点的属性，独立页面会把同一个节点拆到两处看。

交付：无需任何 nebula 侧改动即可看到每节点 RTT 趋势与断连时刻。

**阶段 N1：NAT 端口探测**

- STUN 绑定请求采集本地/外部端口与外部 IP；判据按 13.3 表。
- 记录 WAN 重拨事件，与 N0 的断连时刻叠加展示，验证「重拨 → 重新抢占 → 断连」这条因果链是否成立。
- 按 13.5 的结论接入 lighthouse 视角：`elink-tui --headless` 解析 nebula 日志里的 `certName` 与源地址，按 5 分钟桶聚合到 `lighthouse_observation`，并在 `GET /` 上返回每个 WAN 地址「谁占着默认端口、谁被改写」的判定。

交付：端口争抢与 WAN 重拨可在客户端直接判读，无需登录 VPS。

**日志字段名未经实机确认。** 解析同时接受 `from=` 和 `udpAddr=`，因为哪一个承载源地址取决于 nebula 的消息类型，本地无法验证。首次部署时必须确认解析确实命中，否则会安静地聚合出空表。

**阶段 N2：nebula 指标（条件性）**

先在一台 VPS 上确认 `stats:` 导出与 sshd 调试命令的实际可用指标，再决定是否实现。确认结果为负则本阶段取消，不做替代实现。

### 13.7 验收标准

- 端口争抢发生时，受影响节点在客户端上呈现为可归因的告警状态，而非仅仅「离线」。
- WAN 重拨在时间轴上可见，且与随后的断连事件可对照。
- 隧道重建型抖动（如经 TUN 代理的节点）在 RTT 图上可与单纯高延迟区分。
- 采集本身不产生可观测的额外负载：不新增常驻进程于 macOS 主机，探测频率不高于 60 秒一次。
- 电子墨水屏刷新行为不受本节任何改动影响。

### 13.8 风险

- **RTT 语义被误读**：该值含对端处理时间，UI 与文档必须标注为「同步往返」而非链路延迟，避免下次排障时重演「用错误判据定位错误方向」。
- **P2 指标不存在**：nebula 导出能力未经验证，阶段 N2 设为条件性，不预先在协议中占位字段。
- **覆盖面不完整**：并非所有 nebula 节点都会运行 elink 客户端（DSM 容器、WSL、3B 等尚未纳入）；界面须区分「节点异常」与「节点未接入采集」，不能把后者显示成故障。
- **STUN 依赖外部服务**：单一 STUN 服务器不可用会导致 P1 全部失效，需配置多个并在全部失败时显式降级，不静默留空。

### 13.9 数据存储

#### 与现有 schema 的根本差异

`usage.db` 现有的表全部是聚合表：`daily_model_usage`、`hourly_model_usage`、`daily_category_usage`、`cluster_model_usage` 的主键均为自然键，行数被「天数 × provider × 模型数」天然限制。因此整个 store **没有任何清理逻辑**，因为从来不需要。

链路监控是本项目第一类**无界时序数据**，存储设计必须从这一点出发，否则会在 `usage.db` 里引入需要长期维护的清理路径。

按沿用 sync 的 15 秒探测间隔、7 个 peer 估算：

| 粒度 | 行/天 | 行/年 |
|---|---|---|
| 原始采样 | 40,320 | 约 1470 万 |
| 5 分钟桶 | 2,016 | 约 73 万 |
| 事件 | 个位数 | 数百 |

原始采样一年的行数比现有全部数据高两个数量级，不予存储。5 分钟桶一年 73 万行，可永久保留且无需清理逻辑，重新回到现有表「天然有界」的性质。

#### 表结构

```sql
-- 5 分钟桶，永久保留
CREATE TABLE IF NOT EXISTS link_probe_bucket (
    node_id     TEXT NOT NULL,
    bucket_at   REAL NOT NULL,      -- 桶起始 unix 时间，按 300 秒对齐
    samples     INTEGER NOT NULL,   -- 本桶探测总次数
    ok_samples  INTEGER NOT NULL,   -- 成功次数；samples - ok_samples 即丢样
    rtt_min_ms  INTEGER,            -- 本桶全部失败时为 NULL
    rtt_max_ms  INTEGER,
    rtt_sum_ms  INTEGER,
    PRIMARY KEY (node_id, bucket_at)
);

-- 稀疏事件，永久保留
CREATE TABLE IF NOT EXISTS link_event (
    occurred_at REAL NOT NULL,
    node_id     TEXT NOT NULL,
    kind        TEXT NOT NULL,      -- online|offline|wan_rebind
                                    -- |port_preserved|port_rewritten|stun_unavailable
    detail      TEXT,               -- 例如 "223.95.78.14:4252"
    PRIMARY KEY (occurred_at, node_id, kind)
);
CREATE INDEX IF NOT EXISTS idx_link_event_time ON link_event(occurred_at);
```

时间戳统一用 REAL unix 时间，与 `cluster_nodes`、`provider_usage_cache` 一致，不沿用 `daily_model_usage` 的 TEXT 形式。

#### 写入与参数绑定

`syncPeer` 的每个结果直接 `INSERT … ON CONFLICT DO UPDATE` 进所属桶，不做内存累进。落盘频率因此是每 15 秒一次而非本节初稿设想的每 5 分钟一次：**行数由桶宽决定而非样本数决定**，每天仍只有约 2000 行，SQLite 的写入压力可忽略，换来的是无内存状态、无跨桶边界判断、进程崩溃也不丢当前窗口。初稿的内存累进方案在代码量和故障面上都更差，实现时已放弃。

探测间隔固定为 15 秒，即直接复用 `syncPeer` 既有节奏，不引入独立定时器。**桶宽 5 分钟是由该间隔推导的（每桶 20 个样本）**，两者必须一起调整：若日后将探测与 sync 解耦并放大间隔，桶宽需同比放大以维持每桶约 20 个样本，否则 `rtt_min_ms`/`rtt_max_ms` 会因样本过少而剧烈跳动，失去判读价值。

P1 的 STUN 结果不进桶表，**仅在判定发生跃迁时**写入一条 `link_event`，稳定期不写。家庭出口一天三次重拨即三行。

这里有一个初稿没考虑到的细节：保端口 NAT 下每次探测都用一个新的本地 socket，外部端口必然跟着变，所以**判据只能是外部 IP 变化，不能是端点字符串变化**，否则每分钟都会误报一次重拨。上一次观测到的端点持久化在 `usage_metadata` 里，因此跨进程重启的那次重拨也不会漏记。

#### 不存原始采样的理由

`min`/`avg`/`max` 三条线足以表达抖动：TUN 代理导致的隧道反复重建在桶中表现为 `rtt_max_ms` 飙升而 `rtt_min_ms` 保持正常，与单纯的整体高延迟可直接区分（对应 13.7 的验收项）。精确 p95 需要保留原始行，代价是 1470 万行加一套清理逻辑，与其价值不相称。

确需逐样本细看时，用临时 debug 开关将原始采样写入日志目录的 JSONL，不进数据库、不做保留管理。

#### 边界

- **不跨节点同步。** RTT 是有向量，A→B 与 B→A 本就应分开观察；更实际的理由是同步链路自身故障时，依赖该链路传输故障数据最不可靠。每个节点只存自己的观测。全 mesh 对照视图由 13.5 的方案承担，不扩展 cluster sync 协议。
- **不进 elink-agent。** 树莓派维护自己的 state，N0 与其无关。
- **端点地址不进 `/v1/status`。** `link_event.detail` 含 nebula 地址与端口，而 8765 是无认证的可信局域网服务。此类内网拓扑信息仅在本机 UI 呈现；`cluster` 对象新增的链路字段只包含节点名与状态。这是本节唯一新增的信息暴露面，需在 `docs/protocol.md` 明确写出。

#### 迁移

两张表均为纯新增，无列变更。Swift 侧接在 `createClusterTables` 之后，Rust 侧加入 `create_schema` 的同一个 `execute_batch`，维持两端手工对齐的现有做法。不需要触碰 `PRAGMA table_info` 的列探测逻辑；旧库升级后表为空，UI 须正确处理无历史数据的首次运行状态。
