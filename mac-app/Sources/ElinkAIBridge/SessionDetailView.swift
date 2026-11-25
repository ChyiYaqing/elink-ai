import SwiftUI

/// 单会话实时监控与步骤明细覆盖页（与 UsageStatsView / MeshDetailView / VpsDetailView 同级互斥）。
/// 按需加载单文件最近 80 步，展示 4 宫格指标卡、上下文窗口进度条与逐步骤调用明细。
struct SessionDetailView: View {
    let session: AgentSession
    let theme: PanelTheme
    let loadInspection: (AgentSession, @escaping (SessionInspection) -> Void) -> Void
    let onBack: () -> Void

    @State private var inspection: SessionInspection?
    @State private var onlyAnomalies = false

    private var pet: [String] {
        switch session.kind {
        case .claude: return PixelPet.claude
        case .gemini: return PixelPet.gemini
        case .codex: return PixelPet.codex
        }
    }

    private var accent: Color {
        switch session.kind {
        case .claude: return PanelTheme.claudeColor(dark: theme.dark)
        case .gemini: return PanelTheme.geminiColor(dark: theme.dark)
        case .codex: return PanelTheme.codexColor(dark: theme.dark)
        }
    }

    private var activeMetrics: SessionMetrics {
        inspection?.metrics ?? session.metrics
    }

    private var visibleSteps: [SessionStep] {
        let all = inspection?.steps ?? []
        return onlyAnomalies ? all.filter { !$0.anomalies.isEmpty } : all
    }

    private var anomalyCount: Int {
        (inspection?.steps ?? []).filter { !$0.anomalies.isEmpty }.count
    }

    var body: some View {
        VStack(spacing: 10) {
            header
            metricGrid
            if activeMetrics.contextTokens != nil {
                contextBar
            }
            stepHeader
            stepList
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear { refresh() }
        .onChange(of: session.lastModified) { _ in refresh() }
        .onChange(of: session.metrics) { _ in refresh() }
        .onChange(of: session.id) { _ in
            onlyAnomalies = false
            inspection = nil
            refresh()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                PillButton(title: tr("返回", "Back"), icon: "chevron.left", theme: theme, action: onBack)
                PixelPetView(art: pet, color: accent)
                    .frame(width: 22, height: 15)
                Text(session.nickname ?? (session.title.isEmpty ? session.kind.rawValue : session.title))
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                StateBadge(
                    text: session.isBusy ? tr("运行中", "Working")
                        : session.isLive ? tr("空闲", "Idle")
                        : tr("已结束", "Done"),
                    color: session.isBusy ? theme.statusInfo
                        : session.isLive ? theme.textTertiary
                        : theme.statusHealthy
                )
            }
            HStack(spacing: 6) {
                Text(session.kind.rawValue)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(accent)
                if !session.model.isEmpty {
                    Text("· \(session.model)")
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundStyle(theme.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                if let total = inspection?.totalStepCount, total > 0 {
                    let shown = inspection?.steps.count ?? 0
                    Text(total > shown
                         ? tr("显示最近 \(shown) / 共 \(total) 步", "Latest \(shown) of \(total) steps")
                         : tr("共 \(total) 步", "\(total) steps"))
                        .font(.system(size: 8, weight: .medium, design: .monospaced))
                        .foregroundStyle(theme.textTertiary)
                }
            }
        }
    }

    private var metricGrid: some View {
        let rateText = session.tokensPerSecond.map { String(format: "%.0f tok/s", $0) } ?? "—"
        let ctxText = Self.contextValueText(activeMetrics)
        let cacheText = activeMetrics.cacheHitRate.map { String(format: "%.1f%%", $0 * 100) } ?? "—"
        let costText = activeMetrics.sessionCost.map { UsageFormat.money($0) } ?? "—"
        return VStack(spacing: 6) {
            HStack(spacing: 6) {
                metricTile(title: tr("输出速率", "Output Speed"), value: rateText,
                           detail: tr("最近响应均值", "Recent average"), valueColor: theme.statusInfo)
                metricTile(title: tr("当前上下文", "Context"), value: ctxText,
                           detail: Self.contextSubtext(activeMetrics),
                           valueColor: Self.contextColor(activeMetrics, theme: theme))
            }
            HStack(spacing: 6) {
                metricTile(title: tr("缓存命中率", "Cache Hit"), value: cacheText,
                           detail: activeMetrics.totalTokens > 0
                               ? tr("共 \(UsageFormat.tokens(activeMetrics.totalTokens)) tok",
                                    "\(UsageFormat.tokens(activeMetrics.totalTokens)) tok total")
                               : tr("暂无用量", "No usage"),
                           valueColor: theme.statusHealthy)
                metricTile(title: tr("API 等价成本", "API Equivalent"), value: costText,
                           detail: (inspection?.unpricedModels.isEmpty == false)
                               ? tr("含未定价模型", "Some unpriced")
                               : tr("按官方 API 价折算", "List API estimate"),
                           valueColor: theme.textPrimary)
            }
        }
    }

    private func metricTile(title: String, value: String, detail: String, valueColor: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(theme.textTertiary)
            Text(value)
                .font(.system(size: 13, weight: .bold, design: .monospaced))
                .foregroundStyle(valueColor)
                .lineLimit(1)
            Text(detail)
                .font(.system(size: 8, weight: .medium))
                .foregroundStyle(theme.textTertiary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .sectionCard(theme)
    }

    private var contextBar: some View {
        let ratio = activeMetrics.contextRatio
        let barColor = Self.contextColor(activeMetrics, theme: theme)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(tr("上下文窗口占用", "Context Window"))
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(theme.textSecondary)
                Spacer()
                Text(Self.contextBarCaption(activeMetrics))
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(theme.textSecondary)
            }
            if let ratio {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(theme.progressTrack)
                        Capsule()
                            .fill(barColor)
                            .frame(width: max(3, geo.size.width * CGFloat(ratio)))
                    }
                }
                .frame(height: 5)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .sectionCard(theme)
    }

    private var stepHeader: some View {
        HStack(spacing: 6) {
            Text(tr("调用步骤明细", "Call Steps"))
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(theme.textSecondary)
            Spacer()
            Button {
                onlyAnomalies = false
            } label: {
                Text(tr("全部 (\(inspection?.steps.count ?? 0))", "All (\(inspection?.steps.count ?? 0))"))
                    .font(.system(size: 8, weight: onlyAnomalies ? .medium : .bold))
                    .foregroundStyle(onlyAnomalies ? theme.textTertiary : theme.textPrimary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(onlyAnomalies ? Color.clear : theme.progressTrack))
            }
            .buttonStyle(.plain)
            Button {
                onlyAnomalies = true
            } label: {
                Text(tr("异常 (\(anomalyCount))", "Anomalies (\(anomalyCount))"))
                    .font(.system(size: 8, weight: onlyAnomalies ? .bold : .medium))
                    .foregroundStyle(anomalyCount > 0 ? theme.statusWarning : theme.textTertiary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(onlyAnomalies ? theme.statusWarning.opacity(0.18) : Color.clear))
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private var stepList: some View {
        if inspection == nil {
            VStack(spacing: 6) {
                ProgressView().scaleEffect(0.7)
                Text(tr("正在解析会话步骤…", "Loading session steps…"))
                    .font(.system(size: 9))
                    .foregroundStyle(theme.textTertiary)
            }
            .frame(maxWidth: .infinity, minHeight: 140)
        } else if visibleSteps.isEmpty {
            Text(onlyAnomalies
                 ? tr("没有检测到异常步骤", "No anomalous steps detected")
                 : tr("该会话暂无可解析的 token 调用步骤", "No token-bearing call steps found"))
                .font(.system(size: 9))
                .foregroundStyle(theme.textTertiary)
                .frame(maxWidth: .infinity, minHeight: 120)
        } else {
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: 5) {
                    ForEach(visibleSteps) { step in
                        stepRow(step)
                    }
                }
            }
            .frame(maxHeight: 280)
        }
    }

    private func stepRow(_ step: SessionStep) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Text("#\(step.index)")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(theme.textTertiary)
                if !step.model.isEmpty {
                    Text(step.model)
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .foregroundStyle(theme.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                ForEach(step.anomalies, id: \.self) { anomaly in
                    Text(anomaly.label)
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(anomalyColor(anomaly))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(anomalyColor(anomaly).opacity(theme.dark ? 0.22 : 0.14)))
                }
                Spacer()
                if let ts = step.timestamp {
                    Text(Self.timeFormatter.string(from: ts))
                        .font(.system(size: 8, design: .monospaced))
                        .foregroundStyle(theme.textTertiary)
                }
            }
            HStack(spacing: 6) {
                Text(Self.stepTokensSummary(step))
                    .font(.system(size: 8, weight: .medium, design: .monospaced))
                    .foregroundStyle(theme.textSecondary)
                    .lineLimit(1)
                Spacer()
                Text(Self.stepTimingAndCost(step))
                    .font(.system(size: 8, weight: .semibold, design: .monospaced))
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .sectionCard(theme)
    }

    private func anomalyColor(_ anomaly: StepAnomaly) -> Color {
        switch anomaly {
        case .lowCache: return theme.statusWarning
        case .slowResponse: return theme.statusCritical
        case .compaction: return theme.statusInfo
        }
    }

    private func refresh() {
        let target = session
        loadInspection(target) { result in
            if session.id == target.id {
                inspection = result
            }
        }
    }

    // MARK: - 格式化辅助（静态方法便于单测）

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    static func contextValueText(_ metrics: SessionMetrics) -> String {
        guard let ctx = metrics.contextTokens else { return "—" }
        if let ratio = metrics.contextRatio {
            return "\(Int((ratio * 100).rounded()))%"
        }
        return "\(UsageFormat.tokens(ctx)) ctx"
    }

    static func contextSubtext(_ metrics: SessionMetrics) -> String {
        guard let ctx = metrics.contextTokens else {
            return tr("日志未提供单步上下文", "No per-step context")
        }
        if let limit = metrics.contextWindow {
            return "\(UsageFormat.tokens(ctx)) / \(UsageFormat.tokens(limit))"
        }
        return tr("未知模型窗口上限", "Unknown window limit")
    }

    static func contextBarCaption(_ metrics: SessionMetrics) -> String {
        guard let ctx = metrics.contextTokens else { return "—" }
        if let limit = metrics.contextWindow, let ratio = metrics.contextRatio {
            return "\(UsageFormat.tokens(ctx)) / \(UsageFormat.tokens(limit)) (\(Int((ratio * 100).rounded()))%)"
        }
        return "\(UsageFormat.tokens(ctx)) tokens"
    }

    static func contextColor(_ metrics: SessionMetrics, theme: PanelTheme) -> Color {
        guard let ratio = metrics.contextRatio else { return theme.textPrimary }
        if ratio >= 0.85 { return theme.statusCritical }
        if ratio >= 0.65 { return theme.statusWarning }
        return theme.statusHealthy
    }

    static func stepTokensSummary(_ step: SessionStep) -> String {
        var parts: [String] = []
        if let ctx = step.contextTokens {
            parts.append("ctx \(UsageFormat.tokens(ctx))")
        }
        if step.cacheReadTokens > 0, let hit = step.cacheHitRate {
            parts.append("cache \(Int((hit * 100).rounded()))%")
        } else if step.inputTokens > 0 {
            parts.append("in \(UsageFormat.tokens(step.inputTokens))")
        }
        let gen = step.totalGeneratedTokens
        if gen > 0 {
            parts.append("out \(UsageFormat.tokens(gen))")
        }
        if parts.isEmpty, step.uncategorizedTotalTokens > 0 {
            parts.append("total \(UsageFormat.tokens(step.uncategorizedTotalTokens))")
        }
        return parts.joined(separator: " · ")
    }

    static func stepTimingAndCost(_ step: SessionStep) -> String {
        var parts: [String] = []
        if let sec = step.durationSeconds {
            parts.append(String(format: "%.1fs", sec))
        }
        if let rate = step.tokensPerSecond {
            parts.append(String(format: "%.0f/s", rate))
        }
        if let cost = step.cost {
            parts.append(UsageFormat.money(cost))
        }
        return parts.isEmpty ? "—" : parts.joined(separator: " · ")
    }
}
