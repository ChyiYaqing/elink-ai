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
    @Published var showSettings = false
    @Published var statsProvider: String?
    @Published var launchAtLogin = false
    @Published var deviceHost = ""
    @Published var bridgeAddress = ""
    @Published var settingsMessage: String?

    var onSetMode: ((String) -> Void)?
    var onDeviceRefresh: ((String) -> Void)?
    var onRefreshAll: (() -> Void)?
    var onSaveHost: ((String) -> Void)?
    var onAutoPair: (() -> Void)?
    var onPointHere: (() -> Void)?
    var onOpenDeviceStatus: (() -> Void)?
}

struct UsagePanelView: View {
    @ObservedObject var model: PanelModel
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let theme = PanelTheme(scheme)
        VStack(spacing: 12) {
            header(theme)
            // 设置页作为覆盖层，保持面板尺寸稳定，避免弹窗因高度突变而跳位
            ZStack(alignment: .top) {
                VStack(spacing: 12) {
                    HStack(alignment: .top, spacing: 10) {
                        ProviderCard(name: "Claude", pet: PixelPet.claude,
                                     accent: PanelTheme.claudeColor(dark: theme.dark),
                                     status: model.claude, theme: theme) {
                            withAnimation(.easeOut(duration: 0.2)) { model.statsProvider = "claude" }
                        }
                        ProviderCard(name: "Codex", pet: PixelPet.codex,
                                     accent: PanelTheme.codexColor(dark: theme.dark),
                                     status: model.codex, theme: theme) {
                            withAnimation(.easeOut(duration: 0.2)) { model.statsProvider = "codex" }
                        }
                    }
                    deviceCard(theme)
                }
                .opacity(model.showSettings || model.statsProvider != nil ? 0 : 1)
                .allowsHitTesting(!model.showSettings && model.statsProvider == nil)
                if model.showSettings {
                    settingsCard(theme)
                        .transition(.opacity)
                } else if let provider = model.statsProvider {
                    statsCard(provider, theme)
                        .transition(.opacity)
                }
            }
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

    private func statsCard(_ provider: String, _ theme: PanelTheme) -> some View {
        let claude = provider == "claude"
        return UsageStatsView(
            provider: provider,
            title: claude ? "Claude" : "Codex",
            pet: claude ? PixelPet.claude : PixelPet.codex,
            accent: claude ? PanelTheme.claudeColor(dark: theme.dark)
                           : PanelTheme.codexColor(dark: theme.dark),
            theme: theme,
            onBack: { withAnimation(.easeOut(duration: 0.2)) { model.statsProvider = nil } }
        )
        .glassCard(theme)
    }

    private func settingsCard(_ theme: PanelTheme) -> some View {
        VStack(spacing: 10) {
            ZStack {
                Text("设置")
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundStyle(theme.textPrimary)
                HStack {
                    PillButton(title: "返回", icon: "chevron.left", theme: theme) {
                        withAnimation(.easeOut(duration: 0.2)) { model.showSettings = false }
                    }
                    Spacer()
                }
            }
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 10) {
                    deviceSettings(theme)
                    launchSettings(theme)
                    logSettings(theme)
                    aboutSettings(theme)
                    if let message = model.settingsMessage {
                        Text(message)
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(theme.statusWarning)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func deviceSettings(_ theme: PanelTheme) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            settingsHeader(theme, icon: "display", color: Color(red: 0.35, green: 0.60, blue: 0.95),
                           title: "屏幕连接", subtitle: "树莓派电子纸的地址与配对")
            HStack(spacing: 8) {
                TextField("例如 192.168.1.50:8766", text: $model.deviceHost)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11, design: .monospaced))
                PillButton(title: "保存", icon: "checkmark", theme: theme) {
                    model.onSaveHost?(model.deviceHost)
                }
            }
            HStack(spacing: 8) {
                PillButton(title: "自动配对屏幕", icon: "antenna.radiowaves.left.and.right", theme: theme) {
                    model.onAutoPair?()
                }
                PillButton(title: "设为数据桥接", icon: "point.3.connected.trianglepath.dotted", theme: theme) {
                    model.onPointHere?()
                }
                PillButton(title: "设备状态页", icon: "safari", theme: theme) {
                    model.onOpenDeviceStatus?()
                }
            }
            .disabled(model.busy)
            Text("桥接服务：\(model.bridgeAddress)")
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundStyle(theme.textTertiary)
                .textSelection(.enabled)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(theme)
    }

    private func launchSettings(_ theme: PanelTheme) -> some View {
        HStack(spacing: 8) {
            settingsHeader(theme, icon: "power", color: theme.statusHealthy,
                           title: "开机自启动", subtitle: "登录 macOS 时自动启动 Elink AI")
            Toggle("", isOn: Binding(
                get: { model.launchAtLogin },
                set: { enabled in
                    do {
                        try LaunchAtLogin.setEnabled(enabled)
                        model.launchAtLogin = enabled
                        Log.info("launch at login \(enabled ? "enabled" : "disabled")")
                    } catch {
                        model.settingsMessage = "设置开机自启动失败：\(error.localizedDescription)"
                    }
                }
            ))
            .toggleStyle(.switch)
            .labelsHidden()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(theme)
    }

    private func logSettings(_ theme: PanelTheme) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            settingsHeader(theme, icon: "doc.text.fill", color: Color(red: 0.55, green: 0.52, blue: 0.62),
                           title: "日志", subtitle: "查看桥接应用运行日志")
            WideButton(title: "打开日志文件", icon: "doc.text", theme: theme) {
                if FileManager.default.fileExists(atPath: AppInfo.logPath) {
                    NSWorkspace.shared.open(URL(fileURLWithPath: AppInfo.logPath))
                } else {
                    model.settingsMessage = "暂无日志文件（以开机自启动方式运行后生成于 \(AppInfo.logPath)）"
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(theme)
    }

    private func aboutSettings(_ theme: PanelTheme) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            settingsHeader(theme, icon: "info.circle.fill", color: theme.statusCritical,
                           title: "关于", subtitle: "版本 \(AppInfo.version)")
            WideButton(title: "在 GitHub 查看", icon: "link", theme: theme) {
                NSWorkspace.shared.open(AppInfo.repoURL)
            }
            Text("在 GitHub 反馈问题或参与贡献")
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(theme.textTertiary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(theme)
    }

    private func settingsHeader(_ theme: PanelTheme, icon: String, color: Color,
                                title: String, subtitle: String) -> some View {
        HStack(spacing: 8) {
            ZStack {
                Circle().fill(color)
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 26, height: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundStyle(theme.textPrimary)
                Text(subtitle)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(theme.textTertiary)
            }
            Spacer()
        }
    }

    private func footer(_ theme: PanelTheme) -> some View {
        HStack(spacing: 8) {
            Text("localhost:8765/v1/status")
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundStyle(theme.textTertiary)
            Spacer()
            CircleIconButton(icon: model.showSettings ? "xmark" : "gearshape.fill", theme: theme) {
                withAnimation(.easeOut(duration: 0.2)) { model.showSettings.toggle() }
            }
            CircleIconButton(icon: "power", theme: theme) {
                NSApp.terminate(nil)
            }
        }
    }
}

private struct CircleIconButton: View {
    let icon: String
    let theme: PanelTheme
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(hovering ? Color.white : theme.textSecondary)
                .frame(width: 28, height: 28)
                .background(
                    Circle().fill(hovering ? AnyShapeStyle(theme.accentGradient)
                                           : AnyShapeStyle(theme.glassBackground))
                )
                .overlay(Circle().stroke(theme.glassBorder, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.15), value: hovering)
        .onHover { hovering = $0 }
    }
}

private struct ProviderCard: View {
    let name: String
    let pet: [String]
    let accent: Color
    let status: AgentStatus
    let theme: PanelTheme
    let onOpenStats: () -> Void
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
                Image(systemName: "chart.bar.xaxis")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(theme.textTertiary)
                    .opacity(hovering ? 1 : 0)
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
        .contentShape(RoundedRectangle(cornerRadius: 14))
        .onTapGesture(perform: onOpenStats)
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

struct PillButton: View {
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

private struct WideButton: View {
    let title: String
    let icon: String
    let theme: PanelTheme
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 10, weight: .semibold))
                Text(title).font(.system(size: 11, weight: .semibold, design: .rounded))
            }
            .foregroundStyle(hovering ? Color.white : theme.textSecondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 7)
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
