import SwiftUI

final class PanelModel: ObservableObject {
    @Published var claude = AgentStatus()
    @Published var codex = AgentStatus()
    @Published var updatedText = "用量更新中…"
    @Published var previewImage: NSImage?
    @Published var deviceSummary = "正在连接设备…"
    @Published var deviceBadge = "连接中"
    @Published var deviceHealthy = false
    @Published var mode = "dashboard"
    @Published var busy = false

    var onSetMode: ((String) -> Void)?
    var onDeviceRefresh: ((String) -> Void)?
    var onRefreshAll: (() -> Void)?
}

struct UsagePanelView: View {
    @ObservedObject var model: PanelModel
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let theme = PanelTheme(scheme)
        VStack(spacing: 12) {
            header(theme)
            HStack(alignment: .top, spacing: 10) {
                ProviderCard(name: "Claude", pet: PixelPet.claude,
                             accent: PanelTheme.claudeColor(dark: theme.dark),
                             status: model.claude, theme: theme)
                ProviderCard(name: "Codex", pet: PixelPet.codex,
                             accent: PanelTheme.codexColor(dark: theme.dark),
                             status: model.codex, theme: theme)
            }
            deviceCard(theme)
            footer(theme)
        }
        .padding(16)
        .frame(width: 440)
        .background(theme.backgroundGradient)
    }

    private func header(_ theme: PanelTheme) -> some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(theme.accentGradient)
                Image(systemName: "gauge.with.dots.needle.67percent")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)
            }
            .frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text("Elink AI")
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .foregroundStyle(theme.textPrimary)
                Text(model.updatedText)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(theme.textTertiary)
            }
            Spacer()
            PillButton(title: "刷新", icon: "arrow.clockwise", theme: theme) {
                model.onRefreshAll?()
            }
        }
    }

    private func deviceCard(_ theme: PanelTheme) -> some View {
        VStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "display")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(theme.textSecondary)
                Text("电子纸屏幕")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(theme.textPrimary)
                Spacer()
                StateBadge(text: model.deviceBadge,
                           color: model.deviceHealthy ? theme.statusHealthy : theme.statusWarning)
            }
            if let image = model.previewImage {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.glassBorder, lineWidth: 1))
            } else {
                RoundedRectangle(cornerRadius: 8)
                    .fill(theme.progressTrack)
                    .frame(height: 140)
                    .overlay(
                        Text("等待设备画面…")
                            .font(.system(size: 10))
                            .foregroundStyle(theme.textTertiary)
                    )
            }
            HStack(spacing: 8) {
                Picker("", selection: Binding(
                    get: { model.mode },
                    set: { model.mode = $0; model.onSetMode?($0) }
                )) {
                    Text("双栏").tag("dashboard")
                    Text("Claude").tag("claude")
                    Text("Codex").tag("codex")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 180)
                Spacer()
                PillButton(title: "智能刷新", icon: "wand.and.stars", theme: theme) {
                    model.onDeviceRefresh?("smart")
                }
                PillButton(title: "完整刷新", icon: "arrow.triangle.2.circlepath", theme: theme) {
                    model.onDeviceRefresh?("full")
                }
            }
            .disabled(model.busy)
            Text(model.deviceSummary)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(theme.textTertiary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .glassCard(theme)
    }

    private func footer(_ theme: PanelTheme) -> some View {
        HStack {
            Text("localhost:8765/v1/status")
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundStyle(theme.textTertiary)
            Spacer()
            PillButton(title: "退出", icon: "power", theme: theme) {
                NSApp.terminate(nil)
            }
        }
    }
}

private struct ProviderCard: View {
    let name: String
    let pet: [String]
    let accent: Color
    let status: AgentStatus
    let theme: PanelTheme
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                PixelPetView(art: pet, color: accent)
                    .frame(width: 28, height: 20)
                Text(name)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(theme.textPrimary)
                Spacer()
                StateBadge(text: stateText, color: stateColor)
            }
            if let percent = status.primary.percent {
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text("\(Int(percent))")
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                        .foregroundStyle(theme.textPrimary)
                        .contentTransition(.numericText())
                    Text("%")
                        .font(.system(size: 15, weight: .medium, design: .rounded))
                        .foregroundStyle(theme.textTertiary)
                    Spacer()
                    Text("5 小时")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(theme.textSecondary)
                }
                UsageBar(percent: percent, theme: theme)
                resetLine(status.primary.resetMinutes)
            } else {
                Text(status.error ?? "暂无用量数据")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(theme.textTertiary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
            }
            if let weekly = status.weekly.percent {
                HStack {
                    Text("7 天")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(theme.textSecondary)
                    Spacer()
                    Text("\(Int(weekly))%")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(theme.textPrimary)
                        .contentTransition(.numericText())
                }
                UsageBar(percent: weekly, theme: theme)
                resetLine(status.weekly.resetMinutes)
            }
            if status.tokensToday > 0 {
                HStack(spacing: 3) {
                    Image(systemName: "number.circle.fill")
                        .font(.system(size: 7))
                    Text("今日 \(UsageFormat.tokens(status.tokensToday)) tokens")
                        .font(.system(size: 9, weight: .medium))
                }
                .foregroundStyle(theme.textSecondary)
                ForEach(status.modelUsageToday.prefix(2), id: \.model) { usage in
                    HStack {
                        Text(usage.model)
                            .font(.system(size: 8, weight: .medium))
                            .foregroundStyle(theme.textTertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Text(UsageFormat.tokens(usage.tokens))
                            .font(.system(size: 8, weight: .semibold, design: .monospaced))
                            .foregroundStyle(theme.textTertiary)
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(theme)
        .scaleEffect(hovering ? 1.015 : 1.0)
        .animation(.easeOut(duration: 0.15), value: hovering)
        .onHover { hovering = $0 }
    }

    private func resetLine(_ minutes: Int?) -> some View {
        HStack(spacing: 3) {
            Image(systemName: "clock.fill").font(.system(size: 7))
            Text(minutes.map { "\(MenuBarController.formatMinutes($0)) 后重置" } ?? "无活跃窗口")
                .font(.system(size: 8, weight: .medium))
        }
        .foregroundStyle(theme.textTertiary)
    }

    private var stateText: String {
        if status.needsInput { return "等输入" }
        switch status.state {
        case "working": return "运行中"
        case "idle": return "空闲"
        default: return "离线"
        }
    }

    private var stateColor: Color {
        if status.needsInput { return theme.statusWarning }
        switch status.state {
        case "working": return theme.statusHealthy
        case "idle": return theme.textTertiary
        default: return theme.textTertiary.opacity(0.6)
        }
    }
}

private struct UsageBar: View {
    let percent: Double
    let theme: PanelTheme
    @State private var animated = false

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3).fill(theme.progressTrack)
                RoundedRectangle(cornerRadius: 3)
                    .fill(theme.progressGradient(usedPercent: percent))
                    .frame(width: animated ? geo.size.width * min(100, max(0, percent)) / 100 : 0)
            }
        }
        .frame(height: 5)
        .onAppear {
            withAnimation(.spring(response: 0.8, dampingFraction: 0.7).delay(0.2)) { animated = true }
        }
    }
}

private struct StateBadge: View {
    let text: String
    let color: Color

    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(text).font(.system(size: 8, weight: .semibold))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Capsule().fill(color.opacity(0.15)))
    }
}

private struct PillButton: View {
    let title: String
    let icon: String
    let theme: PanelTheme
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 9, weight: .semibold))
                Text(title).font(.system(size: 10, weight: .semibold, design: .rounded))
            }
            .foregroundStyle(hovering ? Color.white : theme.textSecondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                Capsule().fill(hovering ? AnyShapeStyle(theme.accentGradient)
                                        : AnyShapeStyle(theme.glassBackground))
            )
            .overlay(Capsule().stroke(theme.glassBorder, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.15), value: hovering)
        .onHover { hovering = $0 }
    }
}

private struct GlassCard: ViewModifier {
    let theme: PanelTheme

    func body(content: Content) -> some View {
        content
            .background(RoundedRectangle(cornerRadius: 14).fill(theme.cardGradient))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(theme.glassBorder, lineWidth: 1))
    }
}

private extension View {
    func glassCard(_ theme: PanelTheme) -> some View { modifier(GlassCard(theme: theme)) }
}
