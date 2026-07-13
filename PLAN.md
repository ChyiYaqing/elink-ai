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
