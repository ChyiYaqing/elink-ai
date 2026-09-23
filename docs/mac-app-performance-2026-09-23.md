# Elink AI mac-app 性能排查

排查时间：2026-09-22 至 2026-09-23。本次只诊断，未修改仓库代码、应用配置或已安装应用。

截至 9 月 23 日，关闭面板后仍有持续 CPU 占用，主要来自安装版 `0.1.21-rc8` 每 5 秒重读大量过期会话日志。排查时的仓库代码已在解析前过滤这些日志，但安装版尚未包含该改动。Codex 用量日志在变化后整批重读，是另一处已确认的热点。隐藏面板曾出现 SwiftUI 布局活动，但次日采样显示它不是持续高 CPU 的必要条件；具体动画归因仍待验证。

## 环境与观测

- macOS 27.0 (26A428)，Xcode 27.0 (27A266a)。
- 运行进程 PID 884，/Applications/Elink AI.app/Contents/MacOS/ElinkAIBridge。
- 安装版本 0.1.21-rc8 (44)，已运行约 4 天。
- 排查时仓库 HEAD 65448c4；安装版本与该提交有差异。
- 进程即时 CPU 曾为 39.8%；连续观测出现 22.6%–90.2%。日志最后一次关闭面板为 18:22:03，之后的观测仍为约 22.6%–65.6%。未以窗口 API 独立验证可见性。
- 18:22:12 开始的 20 秒采样中仍有会话扫描、状态日志解析，以及主线程 SwiftUI 布局/渲染。
- 内存 footprint 约 171–194 MiB，历史峰值 888 MiB；这些数据不足以判定内存泄漏。

## 已确认的主要 CPU 热点：安装版会话扫描先解析再过滤

rc8 的 SessionScanner.scanClaude 遍历全部 Claude 顶层 transcript，对每个文件调用 tailInfo，读取最多 128 KiB 尾部并拆分字符串、解析 JSON、构造正文列表；随后 scan 才按存活状态和 6 小时窗口过滤。

本机 137 个顶层 Claude transcript 中，130 个修改时间已超过 6 小时。即使文件完全没有新增内容，下轮仍重新解析。真实采样中两个 ai.elink.agent-sessions 队列均命中 scanClaude → tailInfo → String.split / JSONSerialization。

后台 main.swift:76 每 5 秒轮询；面板 PreviewPopover.swift:377 每 3 秒轮询，且二者分别创建 AgentSessionMonitor。面板打开时重复扫描；关闭面板仅停止面板侧轮询。

当前仓库 AgentSessionMonitor.swift:298 已有解析前过滤，但 rc8 标签不包含此改动。

### 独立对照实验

从 rc8 标签提取原扫描器，用 swiftc -O 编译独立程序，只读本机 transcript；不启动应用、不访问数据库、不执行进程发现。每组扫描 3 次，live/cwd 输入为空，比较当前近期会话路径。日志在实验期间仍可能追加，因此不是冻结数据集。

| 实现 | 平均耗时 | 平均进程 CPU 时间 |
|---|---:|---:|
| rc8 原扫描器 | 567.2 ms | 549.1 ms |
| rc8 仅提前过滤旧且不存活的会话 | 56.6 ms | 55.3 ms |
| 当前 HEAD 扫描器（还包含输出速率计算） | 83.7 ms | 82.1 ms |

三组均返回 9 个会话、85 条顶层正文记录；仅核对数量，没有声称完整语义回归验证。提前过滤使此扫描基准耗时下降约 90%；当前 HEAD 比 rc8 下降约 85%。该比例不是已安装应用整体 CPU 降幅。

## 已确认的次要热点：Codex 日志变化导致整批重读

StatusService.swift:296 readCodex 使用所有文件的最大 mtime 作为整批缓存条件。只要该条件改变，就完整读取当天修改过的文件，并解析每行，随后再次遍历查找 token_count 的配额数据。

本机测量时当天修改的 Codex 文件为 11 个、共约 5.5 MiB。StatusService.swift:52 在 lock.holding 内调用 readLogs；缓存周期 5 秒。实际线程采样命中 readCodex、codexUsageEvents，HTTP 请求队列也存在锁等待。

18:22 这一分钟已有日志中的 /v1/status 共 24 次请求：中位数 4 ms、P95 852 ms、最大 1378 ms。不是额外负载测试。慢请求与缓存未命中路径一致；没有证明每个慢请求都只由 Codex 解析造成。

## 仍待隔离的界面开销

面板关闭日志之后的采样中，主线程仍执行 NSHostingView.layout、SwiftUI ViewGraph 与 CoreAnimation 提交。AgentSessionsCard.swift:305 在 onAppear 启动 repeatForever 动画；PreviewPopover.swift:287 关闭时停止轮询但未显式销毁视图或取消动画。

这是隐藏视图动画持续运行的嫌疑点，尚未通过动画禁用 A/B 实验确认。当前采样没有证据把卡顿归结为主线程长期死锁；也不能单靠这些采样排除短暂锁竞争。

## 建议处理顺序

1. 将已存在的旧会话提前过滤改动纳入实际安装构建，并重新测量打开/关闭面板的 CPU。
2. 后台和面板共享会话扫描结果；对未变化文件缓存解析结果，保留独立存活/忙碌状态更新。
3. Codex 按文件缓存或增量解析，缩短 StatusService 锁持有时间。
4. 对隐藏面板的无限动画做关闭前后对照，确认后再修正生命周期。

## 原始材料

以下采样与基准结果存放在本机临时目录，供本次排查复核，不随仓库提交。

- /private/tmp/elink-perf-sample.txt：12 秒操作期间采样。
- /private/tmp/elink-perf-baseline.txt：20 秒后续采样。
- /private/tmp/elink-perf-bench/rc8-results.txt
- /private/tmp/elink-perf-bench/filter-results.txt
- /private/tmp/elink-perf-bench/current-results.txt
- 同目录保留基准 main.swift、rc8 源码及仅提前过滤的实验副本。

排查状态：主要 CPU 根因已定位并由独立实验验证；应用尚未修复或替换，界面动画归因仍待验证。

## 用户确认关闭面板后的复测

用户明确确认关闭面板后 CPU 仍高。18:26:39 再做 15 秒线程采样，同时以 2 秒间隔记录 CPU；日志最近一次关闭为 18:22:03，此后未见再次打开记录。

排除 top 首个无差分样本后，8 次 CPU 样本平均 37.6%，范围 21.0%–65.1%。仅剩一套会话扫描队列，但主线程仍命中 NSHostingView.layout / SwiftUI render，HTTP 队列仍在 readCodex 路径解析日志。确认持续开销不依赖面板打开；隐藏视图刷新已重复观测到，是否具体由 repeatForever 动画引起仍需 A/B 验证。

新增原始记录：/private/tmp/elink-perf-confirmed-closed.txt、/private/tmp/elink-perf-confirmed-closed-cpu.txt。

## 2026-09-23 继续排查与结论修正

同一运行进程 PID 884（安装版仍为 rc8）。关闭面板后的 2 秒间隔 top 序列，排除首个无差分样本后，11 次 CPU 样本为 9.5、17.5、11.3、28.0、0.5、32.0、1.5、26.7、7.6、6.7、29.4%，平均 15.5%。

15 秒采样里后台 ai.elink.agent-sessions 仍有 228/1273 个样本处于活动队列，其中 148 个命中 SessionScanner.scan，另有 ProcessDiscovery.run。HTTP 队列中 readLogs 及 readCodex 继续出现。主线程仅 2 次命中 NSHostingView.layout，说明隐藏界面渲染在本次窗口内不是主要耗时，不能解释全部持续 CPU。昨天隐藏界面渲染是可观察到的额外开销，但尚未定位为特定动画，也不能称为持续高 CPU 的必要条件。

当天 6 小时内修改的 Claude、Codex 会话文件各 2 个；这与后台扫描主要浪费在读取旧文件的结论一致。静态 rc8 基准约 549 ms CPU/轮，每 5 秒一次，相当于约 11% 的单核预算，与今天实测平均 15.5% 同量级。该换算只作量级交叉验证，运行中的进程发现、Codex 解析和其他工作也会消耗 CPU。

修正后的优先级：先把已经存在的“旧会话解析前过滤”改动安装到实际运行版本；继续处理 Codex 重解析。对隐藏面板动画只保留独立嫌疑，等后续 A/B 证据，不应把它列为解决持续高 CPU 的先决条件。

新增原始材料：/private/tmp/elink-perf-sep23-cpu.txt、/private/tmp/elink-perf-sep23-sample.txt。
