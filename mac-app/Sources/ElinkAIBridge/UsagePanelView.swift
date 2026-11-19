import AppKit
import SwiftUI

enum ClaudeCredentialState {
    case automatic
    case configured
    case invalid
    case unavailable
}

final class PanelModel: ObservableObject {
    @Published var claude = AgentStatus()
    @Published var codex = AgentStatus()
    @Published var claudeCost: CostSummary?
    @Published var codexCost: CostSummary?
    @Published var updatedText = tr("用量更新中…", "Updating usage…")
    @Published var previewImage: NSImage?
    @Published var deviceSummary = tr("正在连接设备…", "Connecting to device…")
    @Published var deviceBadge = tr("连接中", "Connecting")
    @Published var deviceHealthy = false
    @Published var mode = "dashboard"
    /// 屏幕此刻停在设备监控页（空闲填充页）上，而不是用量面板。
    @Published var showsMonitor = false
    @Published var busy = false
    @Published var refreshingUsage = false
    @Published var showSettings = false
    @Published var statsProvider: String?
    @Published var showReceipt = false
    /// 本机出口的 NAT 观测，由 LinkMonitor 经 PreviewPopoverController 同步过来
    @Published var natObservation: StunObservation?
    @Published var natUnavailable = false
    @Published var lighthouseURL = ""
    var onSaveLighthouse: ((String) -> Void)?
    @Published var showMesh = false
    @Published var showVPS = false
    /// 只带 veid 与显示名。api_key 永远不进面板模型——UI 从不需要回显它。
    @Published var vpsServers: [(veid: String, label: String)] = []
    @Published var vpsSaving = false
    var onSaveVPS: ((String, String, String, @escaping (Bool) -> Void) -> Void)?
    var onRemoveVPS: ((String) -> Void)?
    var onRenameVPS: ((String, String) -> Void)?
    @Published var launchAtLogin = false
    @Published var deviceHost = ""
    @Published var bridgeAddress = ""
    @Published var deviceConnectionEnabled = true
    @Published var settingsMessage: String?
    @Published var agentSessions: [AgentSession] = []
    @Published var agentSessionsEnabled = true
    @Published var claudeCredentialState: ClaudeCredentialState = .automatic
    @Published var claudeCredentialValidating = false
    @Published var language: AppLanguage = AppLanguage.current
    @Published var theme: AppTheme = AppTheme.current
    @Published var panelMaxHeight: CGFloat = 700

    var onSetMode: ((String) -> Void)?
    var onDeviceRefresh: ((String) -> Void)?
    var onRefreshAll: (() -> Void)?
    var onSaveHost: ((String) -> Void)?
    var onSetDeviceConnectionEnabled: ((Bool) -> Void)?
    var onAutoPair: (() -> Void)?
    var onPointHere: (() -> Void)?
    var onOpenDeviceStatus: (() -> Void)?
    var onSetAgentSessionsEnabled: ((Bool) -> Void)?
    var onSaveClaudeToken: ((String, @escaping (Bool) -> Void) -> Void)?
    var onRemoveClaudeToken: (() -> Bool)?

    var canRemoveClaudeCredential: Bool {
        claudeCredentialState == .configured || claudeCredentialState == .invalid
    }
}

struct UsagePanelView: View {
    @ObservedObject var model: PanelModel
    @ObservedObject var updater: UpdateChecker
    @ObservedObject var cluster: ClusterManager
    @ObservedObject var mesh: MeshMonitor
    @ObservedObject var kiwi: KiwiVMMonitor
    @Environment(\.colorScheme) private var scheme
    @State private var updatesExpanded = false
    @State private var deviceSettingsExpanded = false
    @State private var clusterExpanded = false
    @State private var clusterAddress = ""
    @State private var clusterCode = ""
    @State private var clusterMessage: String?
    @State private var pairingCodeCopied = false
    @State private var showClusterAdvanced = false
    @State private var showLeaveClusterConfirmation = false
    @State private var claudeTokenInput = ""
    @State private var showRemoveClaudeTokenConfirmation = false
    @State private var expandedNodeID: String?
    @State private var vpsExpanded = false
    @State private var vpsVeidInput = ""
    @State private var vpsLabelInput = ""
    @State private var vpsKeyInput = ""
    @State private var vpsPendingRemoval: String?
    @State private var vpsEditingVeid: String?
    @State private var vpsEditLabel = ""
    @State private var vpsEditKey = ""

    init(model: PanelModel, updater: UpdateChecker, cluster: ClusterManager,
         mesh: MeshMonitor, kiwi: KiwiVMMonitor,
         initialDeviceSettingsExpanded: Bool = false,
         initialClusterExpanded: Bool = false,
         initialExpandedNodeID: String? = nil,
         initialVPSExpanded: Bool = false) {
        self.model = model
        self.updater = updater
        self.cluster = cluster
        self.mesh = mesh
        self.kiwi = kiwi
        _deviceSettingsExpanded = State(initialValue: initialDeviceSettingsExpanded)
        _clusterExpanded = State(initialValue: initialClusterExpanded)
        _expandedNodeID = State(initialValue: initialExpandedNodeID)
        _vpsExpanded = State(initialValue: initialVPSExpanded)
    }

    var body: some View {
        let theme = PanelTheme(scheme, model.theme)
        VStack(spacing: 12) {
            header(theme)
            // 设置页作为覆盖层，保持面板尺寸稳定，避免弹窗因高度突变而跳位
            ZStack(alignment: .top) {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 12) {
                        // fixedSize 让 HStack 取最高卡片的高度，两张卡片再撑满对齐
                        HStack(alignment: .top, spacing: 10) {
                            ProviderCard(name: "Claude", pet: PixelPet.claude,
                                         accent: PanelTheme.claudeColor(dark: theme.dark),
                                         status: model.claude, theme: theme,
                                         cost: model.claudeCost) {
                                Log.user("open Claude usage statistics")
                                withAnimation(.easeOut(duration: 0.2)) { model.statsProvider = "claude" }
                            }
                            ProviderCard(name: "Codex", pet: PixelPet.codex,
                                         accent: PanelTheme.codexColor(dark: theme.dark),
                                         status: model.codex, theme: theme,
                                         cost: model.codexCost) {
                                Log.user("open Codex usage statistics")
                                withAnimation(.easeOut(duration: 0.2)) { model.statsProvider = "codex" }
                            }
                        }
                        .fixedSize(horizontal: false, vertical: true)
                        if model.agentSessionsEnabled && !model.agentSessions.isEmpty {
                            AgentSessionsCard(sessions: model.agentSessions, theme: theme)
                        }
                        if kiwi.configured {
                            VpsCard(monitor: kiwi, theme: theme) {
                                Log.user("open vps detail")
                                withAnimation(.easeOut(duration: 0.2)) { model.showVPS = true }
                            }
                        }
                        meshCard(theme)
                        if model.deviceConnectionEnabled || overlayVisible {
                            deviceCard(theme)
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
                .opacity(overlayVisible ? 0 : 1)
                .allowsHitTesting(!overlayVisible)
                if model.showSettings {
                    settingsCard(theme)
                        .transition(.opacity)
                } else if let provider = model.statsProvider {
                    statsCard(provider, theme)
                        .transition(.opacity)
                } else if model.showReceipt {
                    ReceiptView(theme: theme, clusterEnabled: cluster.enabled) {
                        Log.user("close usage receipt")
                        withAnimation(.easeOut(duration: 0.2)) { model.showReceipt = false }
                    }
                    .glassCard(theme)
                    .transition(.opacity)
                } else if model.showMesh {
                    meshDetail(theme)
                        .transition(.opacity)
                } else if model.showVPS {
                    VpsDetailView(monitor: kiwi, theme: theme,
                                  onRename: { veid, label in model.onRenameVPS?(veid, label) }) {
                        Log.user("close vps detail")
                        withAnimation(.easeOut(duration: 0.2)) { model.showVPS = false }
                    }
                    .transition(.opacity)
                }
            }
            footer(theme)
        }
        .padding(16)
        .frame(width: 440)
        .frame(maxHeight: model.panelMaxHeight)
        .background(theme.backgroundGradient)
    }

    /// 设置、用量统计、对账单、Nebula、VPS 几页互斥，都盖在主列表上。
    private var overlayVisible: Bool {
        model.showSettings || model.statsProvider != nil || model.showReceipt
            || model.showMesh || model.showVPS
    }

    private func header(_ theme: PanelTheme) -> some View {
        HStack(spacing: 10) {
            Group {
                if let logo = AppLogo.image {
                    Image(nsImage: logo)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                } else {
                    RoundedRectangle(cornerRadius: 8).fill(theme.accentGradient)
                }
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
            if cluster.enabled {
                StateBadge(
                    text: tr("\(max(1, cluster.nodes.filter { $0.isOnline() }.count))/\(max(1, cluster.nodes.count)) 台",
                             "\(max(1, cluster.nodes.filter { $0.isOnline() }.count))/\(max(1, cluster.nodes.count)) Hosts"),
                    color: cluster.nodes.allSatisfy { $0.isOnline() }
                        ? theme.statusHealthy : theme.statusWarning
                )
            }
            PillButton(title: tr("对账单", "Receipt"), icon: "printer", theme: theme) {
                Log.user("open usage receipt")
                withAnimation(.easeOut(duration: 0.2)) { model.showReceipt = true }
            }
            .disabled(overlayVisible)
            PillButton(title: model.refreshingUsage ? tr("刷新中", "Refreshing") : tr("刷新", "Refresh"),
                       icon: "arrow.clockwise", theme: theme) {
                model.onRefreshAll?()
            }
            .disabled(model.refreshingUsage)
        }
    }

    private func deviceCard(_ theme: PanelTheme) -> some View {
        VStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "display")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(theme.textSecondary)
                Text(tr("电子纸屏幕", "E-Paper Screen"))
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
                        Text(tr("等待设备画面…", "Waiting for device screen…"))
                            .font(.system(size: 10))
                            .foregroundStyle(theme.textTertiary)
                    )
            }
            if model.showsMonitor {
                // 屏上是监控页时，下面的模式选择器决定的是「切回用量面板后」的排版，
                // 不是此刻屏幕的内容。不说清楚就会以为选择器坏了。
                Text(tr("屏幕空闲中，正显示设备监控页；有 AI 活动时自动切回用量面板。",
                        "Idle: the panel is showing the device monitor and returns to usage when AI activity resumes."))
                    .font(.system(size: 10))
                    .foregroundStyle(theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: 8) {
                Picker("", selection: Binding(
                    get: { model.mode },
                    set: { model.mode = $0; model.onSetMode?($0) }
                )) {
                    Text(tr("双栏", "Dual")).tag("dashboard")
                    Text("Claude").tag("claude")
                    Text("Codex").tag("codex")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .tint(theme.controlAccent)
                .frame(width: 180)
                Spacer()
                PillButton(title: tr("智能刷新", "Smart Refresh"), icon: "wand.and.stars", theme: theme) {
                    model.onDeviceRefresh?("smart")
                }
                PillButton(title: tr("完整刷新", "Full Refresh"), icon: "arrow.triangle.2.circlepath", theme: theme) {
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
            clusterNodes: cluster.enabled ? cluster.nodes : [],
            onBack: {
                Log.user("close \(claude ? "Claude" : "Codex") usage statistics")
                withAnimation(.easeOut(duration: 0.2)) { model.statsProvider = nil }
            }
        )
        .glassCard(theme)
    }

    private func meshDetail(_ theme: PanelTheme) -> some View {
        MeshDetailView(mesh: mesh, panel: model, theme: theme) {
            Log.user("close nebula overlay")
            withAnimation(.easeOut(duration: 0.2)) { model.showMesh = false }
        }
        // 和用量统计页同一层外壳：表头也在卡里，两页翻过去边界不跳
        .glassCard(theme)
    }

    private func settingsCard(_ theme: PanelTheme) -> some View {
        VStack(spacing: 10) {
            ZStack {
                Text(tr("设置", "Settings"))
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundStyle(theme.textPrimary)
                HStack {
                    PillButton(title: tr("返回", "Back"), icon: "chevron.left", theme: theme) {
                        Log.user("close settings")
                        withAnimation(.easeOut(duration: 0.2)) { model.showSettings = false }
                    }
                    Spacer()
                }
            }
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 10) {
                    deviceSettings(theme)
                    launchSettings(theme)
                    languageSettings(theme)
                    themeSettings(theme)
                    agentSessionsSettings(theme)
                    claudeCredentialSettings(theme)
                    clusterSettings(theme)
                    vpsSettings(theme)
                    logSettings(theme)
                    updateSettings(theme)
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
            HStack(spacing: 8) {
                Button {
                    guard model.deviceConnectionEnabled else { return }
                    withAnimation(.easeOut(duration: 0.2)) {
                        deviceSettingsExpanded.toggle()
                    }
                } label: {
                    settingsHeader(
                        theme,
                        icon: "display",
                        color: theme.statusInfo,
                        title: tr("屏幕连接", "Screen Connection"),
                        subtitle: model.deviceConnectionEnabled
                            ? tr("树莓派电子纸的地址与配对", "Raspberry Pi e-paper address and pairing")
                            : tr("已关闭 · 本机仅采集与同步用量", "Off · this host only collects and syncs usage"),
                        expanded: deviceSettingsExpanded
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!model.deviceConnectionEnabled)
                .accessibilityValue(deviceSettingsExpanded ? tr("已展开", "Expanded") : tr("已折叠", "Collapsed"))
                Toggle("", isOn: Binding(
                    get: { model.deviceConnectionEnabled },
                    set: { enabled in
                        if !enabled {
                            withAnimation(.easeOut(duration: 0.2)) {
                                deviceSettingsExpanded = false
                            }
                        }
                        model.onSetDeviceConnectionEnabled?(enabled)
                    }
                ))
                .toggleStyle(.switch)
                .tint(theme.statusHealthy)
                .scaleEffect(0.78)
                .labelsHidden()
                .accessibilityLabel(tr("屏幕连接", "Screen Connection"))
                .accessibilityHint(model.deviceConnectionEnabled
                    ? tr("关闭电子纸设备发现、轮询与刷新", "Turn off e-paper device discovery, polling and refresh")
                    : tr("开启电子纸设备连接", "Turn on e-paper device connection"))
            }

            if model.deviceConnectionEnabled && deviceSettingsExpanded {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        TextField(tr("例如 192.168.1.50:8766", "e.g. 192.168.1.50:8766"), text: $model.deviceHost)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 11, design: .monospaced))
                        PillButton(title: tr("保存", "Save"), icon: "checkmark", theme: theme) {
                            model.onSaveHost?(model.deviceHost)
                        }
                    }
                    HStack(spacing: 8) {
                        PillButton(title: tr("自动配对屏幕", "Auto-Pair Screen"), icon: "antenna.radiowaves.left.and.right", theme: theme) {
                            model.onAutoPair?()
                        }
                        PillButton(title: tr("设为数据桥接", "Set as Data Bridge"), icon: "point.3.connected.trianglepath.dotted", theme: theme) {
                            model.onPointHere?()
                        }
                        PillButton(title: tr("设备状态页", "Device Status Page"), icon: "safari", theme: theme) {
                            model.onOpenDeviceStatus?()
                        }
                    }
                    .disabled(model.busy)
                    Text(tr("桥接服务：\(model.bridgeAddress)", "Bridge service: \(model.bridgeAddress)"))
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundStyle(theme.textTertiary)
                        .textSelection(.enabled)
                }
                .transition(.opacity)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(theme)
    }

    private func launchSettings(_ theme: PanelTheme) -> some View {
        HStack(spacing: 8) {
            settingsHeader(theme, icon: "power", color: theme.statusHealthy,
                           title: tr("开机自启动", "Launch at Login"),
                           subtitle: tr("登录 macOS 时自动启动 Elink AI", "Launch Elink AI automatically when you log in to macOS"))
            Toggle("", isOn: Binding(
                get: { model.launchAtLogin },
                set: { enabled in
                    do {
                        try LaunchAtLogin.setEnabled(enabled)
                        model.launchAtLogin = enabled
                        Log.user("launch at login \(enabled ? "enabled" : "disabled")")
                    } catch {
                        Log.warning("set launch at login failed: \(error.localizedDescription)", category: "user")
                        model.settingsMessage = tr("设置开机自启动失败：\(error.localizedDescription)",
                                                   "Failed to set launch at login: \(error.localizedDescription)")
                    }
                }
            ))
            .toggleStyle(.switch)
            .tint(theme.statusHealthy)
            .scaleEffect(0.78)
            .labelsHidden()
            .accessibilityLabel(tr("开机自启动", "Launch at Login"))
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(theme)
    }

    private func languageSettings(_ theme: PanelTheme) -> some View {
        HStack(spacing: 8) {
            settingsHeader(theme, icon: "globe",
                           color: PanelTheme.codexColor(dark: theme.dark),
                           title: tr("语言", "Language"),
                           subtitle: tr("界面显示语言", "Interface display language"))
            Picker("", selection: Binding(
                get: { model.language },
                set: { value in
                    AppLanguage.current = value
                    model.language = value
                }
            )) {
                Text("中文").tag(AppLanguage.chinese)
                Text("English").tag(AppLanguage.english)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .tint(theme.controlAccent)
            .frame(width: 140)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(theme)
    }

    private func themeSettings(_ theme: PanelTheme) -> some View {
        HStack(spacing: 8) {
            settingsHeader(theme, icon: "paintpalette.fill",
                           color: PanelTheme.claudeColor(dark: theme.dark),
                           title: tr("主题", "Theme"),
                           subtitle: tr("面板配色", "Panel color scheme"))
            Picker("", selection: Binding(
                get: { model.theme },
                set: { value in
                    Log.user("switch theme to \(value.rawValue)")
                    AppTheme.current = value
                    model.theme = value
                }
            )) {
                ForEach(AppTheme.allCases, id: \.self) { option in
                    Text(option.label).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .tint(theme.controlAccent)
            .frame(width: 140)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(theme)
    }

    private func agentSessionsSettings(_ theme: PanelTheme) -> some View {
        HStack(spacing: 8) {
            settingsHeader(theme, icon: "terminal.fill",
                           color: theme.textSecondary,
                           title: tr("Agent 会话", "Agent Sessions"),
                           subtitle: tr("在面板显示运行中的 Claude Code / Codex 会话",
                                        "Show running Claude Code / Codex sessions in the panel"))
            Toggle("", isOn: Binding(
                get: { model.agentSessionsEnabled },
                set: { model.onSetAgentSessionsEnabled?($0) }
            ))
            .toggleStyle(.switch)
            .tint(theme.statusHealthy)
            .scaleEffect(0.78)
            .labelsHidden()
            .accessibilityLabel(tr("Agent 会话", "Agent Sessions"))
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(theme)
    }

    private func claudeCredentialSettings(_ theme: PanelTheme) -> some View {
        let configured = model.claudeCredentialState == .configured
        let invalid = model.claudeCredentialState == .invalid
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                settingsHeader(
                    theme,
                    icon: "key.fill",
                    color: PanelTheme.claudeColor(dark: theme.dark),
                    title: tr("Claude 认证", "Claude Authentication"),
                    subtitle: claudeCredentialSubtitle
                )
                StateBadge(
                    text: claudeCredentialBadge,
                    color: model.claudeCredentialValidating ? theme.statusInfo
                        : configured ? theme.statusHealthy
                        : invalid || model.claudeCredentialState == .unavailable
                            ? theme.statusWarning : theme.textTertiary
                )
            }

            Text(tr("先运行 `claude setup-token`，再把生成的长期 token 粘贴到这里。Elink 不会将它写入配置或日志。",
                    "Run `claude setup-token`, then paste the generated long-lived token here. Elink never writes it to settings or logs."))
                .font(.system(size: 8, weight: .medium))
                .foregroundStyle(theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                SecureField(
                    configured
                        ? tr("粘贴新 token 以替换", "Paste a new token to replace")
                        : invalid
                            ? tr("粘贴新 token 以修复", "Paste a new token to repair")
                            : tr("粘贴长期 token", "Paste long-lived token"),
                    text: $claudeTokenInput
                )
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 10, design: .monospaced))
                .onSubmit { saveClaudeToken() }
                .disabled(model.claudeCredentialValidating)
                PillButton(
                    title: model.claudeCredentialValidating
                        ? tr("验证中", "Validating")
                        : configured ? tr("替换", "Replace")
                            : invalid ? tr("修复", "Repair") : tr("保存", "Save"),
                    icon: model.claudeCredentialValidating ? "hourglass" : "checkmark.shield.fill",
                    theme: theme
                ) { saveClaudeToken() }
                .disabled(model.claudeCredentialValidating
                          || claudeTokenInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            HStack(spacing: 8) {
                WideButton(title: tr("复制生成命令", "Copy Setup Command"),
                           icon: "doc.on.doc", theme: theme) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString("claude setup-token", forType: .string)
                    model.settingsMessage = tr("已复制：claude setup-token",
                                               "Copied: claude setup-token")
                }
                if model.canRemoveClaudeCredential {
                    DestructiveButton(title: invalid
                                      ? tr("重置 Elink token", "Reset Elink Token")
                                      : tr("移除 Elink token", "Remove Elink Token"),
                                      icon: "trash", theme: theme,
                                      hint: tr("删除 Elink 自己的 Keychain 条目并恢复自动凭据发现",
                                               "Deletes Elink's Keychain item and restores automatic credential discovery")) {
                        showRemoveClaudeTokenConfirmation = true
                    }
                    .disabled(model.claudeCredentialValidating)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(theme)
        .alert(tr("移除 Elink 的 Claude token？", "Remove Elink's Claude token?"),
               isPresented: $showRemoveClaudeTokenConfirmation) {
            Button(tr("取消", "Cancel"), role: .cancel) {}
            Button(tr("移除", "Remove"), role: .destructive) {
                if model.onRemoveClaudeToken?() == true { claudeTokenInput = "" }
            }
        } message: {
            Text(tr("只会删除 Elink 自己的 Keychain 条目；Claude Code 的登录不会改变。Elink 将恢复自动发现凭据。",
                    "Only Elink's Keychain item is deleted. Claude Code stays signed in and Elink returns to automatic credential discovery."))
        }
    }

    private var claudeCredentialSubtitle: String {
        switch model.claudeCredentialState {
        case .automatic:
            return tr("独立于终端进程，避免短期凭据过期",
                      "Independent of terminal processes and short-lived credentials")
        case .configured:
            return tr("长期 token 已安全存入本机 Keychain",
                      "Long-lived token stored securely in this Mac's Keychain")
        case .invalid:
            return tr("Keychain 条目已损坏，请修复或重置",
                      "The Keychain item is invalid; repair or reset it")
        case .unavailable:
            return tr("无法访问 Elink Keychain",
                      "Elink's Keychain item is unavailable")
        }
    }

    private var claudeCredentialBadge: String {
        if model.claudeCredentialValidating { return tr("验证中", "Validating") }
        switch model.claudeCredentialState {
        case .automatic: return tr("自动", "Automatic")
        case .configured: return tr("已配置", "Configured")
        case .invalid: return tr("需重置", "Reset needed")
        case .unavailable: return tr("不可用", "Unavailable")
        }
    }

    private func saveClaudeToken() {
        guard !model.claudeCredentialValidating else { return }
        model.onSaveClaudeToken?(claudeTokenInput) { saved in
            if saved { claudeTokenInput = "" }
        }
    }

    // MARK: - KiwiVM

    /// 搬瓦工 VPS 的接入。放在多机同步之后、日志之前：它和集群同属「外部服务」，
    /// 而插进 Claude 认证与 Agent 会话中间会把那两节本地凭据的设置拆散。
    private func vpsSettings(_ theme: PanelTheme) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeOut(duration: 0.2)) { vpsExpanded.toggle() }
            } label: {
                settingsHeader(
                    theme,
                    icon: "server.rack",
                    color: theme.statusInfo,
                    title: tr("VPS 监控", "VPS Monitoring"),
                    subtitle: Self.vpsSettingsSubtitle(count: model.vpsServers.count),
                    expanded: vpsExpanded
                )
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(vpsExpanded ? tr("已展开", "Expanded") : tr("已折叠", "Collapsed"))

            if vpsExpanded {
                VStack(alignment: .leading, spacing: 9) {
                    Text(tr("在 KiwiVM 面板的 API 页面开启 API 并复制 VM ID 与 API key。Elink 只读取状态，不会执行开关机。",
                            "Enable the API on KiwiVM's API page, then copy the VM ID and API key. Elink only reads status; it never starts or stops a VPS."))
                        .font(.system(size: 8, weight: .medium))
                        .foregroundStyle(theme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)

                    ForEach(model.vpsServers, id: \.veid) { server in
                        if vpsEditingVeid == server.veid {
                            vpsEditor(server, theme)
                        } else {
                            HStack(spacing: 8) {
                                Text(server.label)
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(theme.textPrimary)
                                    .lineLimit(1)
                                Text(server.veid)
                                    .font(.system(size: 9, design: .monospaced))
                                    .foregroundStyle(theme.textTertiary)
                                Spacer(minLength: 0)
                                RowIconButton(
                                    icon: "pencil", theme: theme,
                                    label: tr("编辑 \(server.label)", "Edit \(server.label)"),
                                    hint: tr("修改名称或更换 API key", "Rename it or replace its API key"),
                                    hoverColor: theme.statusInfo
                                ) {
                                    vpsEditLabel = server.label
                                    vpsEditKey = ""
                                    vpsEditingVeid = server.veid
                                }
                                .disabled(model.vpsSaving)
                                RowIconButton(
                                    icon: "trash", theme: theme,
                                    label: tr("移除 \(server.label)", "Remove \(server.label)"),
                                    hint: tr("删除这台的 API key 并停止读取它",
                                             "Deletes this server's API key and stops reading it")
                                ) { vpsPendingRemoval = server.veid }
                                .disabled(model.vpsSaving)
                            }
                        }
                    }

                    if model.vpsServers.count < KiwiVMCredentialStore.maxServers {
                        HStack(spacing: 6) {
                            TextField(tr("VM ID", "VM ID"), text: $vpsVeidInput)
                                .frame(width: 76)
                            TextField(tr("名称", "Name"), text: $vpsLabelInput)
                                .frame(width: 96)
                            SecureField(tr("API key", "API key"), text: $vpsKeyInput)
                                .onSubmit { saveVPS() }
                        }
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 10, design: .monospaced))
                        .disabled(model.vpsSaving)

                        PillButton(title: model.vpsSaving
                                    ? tr("验证中", "Validating")
                                    : tr("添加服务器", "Add Server"),
                                   icon: model.vpsSaving ? "hourglass" : "checkmark.shield.fill",
                                   theme: theme) { saveVPS() }
                            .disabled(model.vpsSaving
                                      || vpsVeidInput.trimmingCharacters(in: .whitespaces).isEmpty
                                      || vpsKeyInput.trimmingCharacters(in: .whitespaces).isEmpty)
                    } else {
                        Text(tr("已达到 \(KiwiVMCredentialStore.maxServers) 台上限，移除一台后才能再添加",
                                "At the \(KiwiVMCredentialStore.maxServers)-server limit; remove one to add another"))
                            .font(.system(size: 8, weight: .medium))
                            .foregroundStyle(theme.textTertiary)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(theme)
        .alert(tr("移除这台服务器？", "Remove this server?"),
               isPresented: Binding(get: { vpsPendingRemoval != nil },
                                    set: { if !$0 { vpsPendingRemoval = nil } })) {
            Button(tr("取消", "Cancel"), role: .cancel) { vpsPendingRemoval = nil }
            Button(tr("移除", "Remove"), role: .destructive) {
                if let veid = vpsPendingRemoval { model.onRemoveVPS?(veid) }
                vpsPendingRemoval = nil
            }
        } message: {
            Text(tr("只会删除本机保存的 API key，服务器本身不受影响。",
                    "Only the API key stored on this Mac is deleted. The server itself is untouched."))
        }
    }

    static func vpsSettingsSubtitle(count: Int) -> String {
        count == 0
            ? tr("未添加服务器 · 添加后在主页显示", "No servers yet · they appear on the main page once added")
            : tr("\(count) 台 · 面板打开时每 5 分钟读取一次",
                 "\(count) server(s) · read every 5 minutes while the panel is open")
    }

    /// VM ID 不给改：它是这台的身份，换 VM ID 就是换一台，走删除再添加。
    private func vpsEditor(_ server: (veid: String, label: String), _ theme: PanelTheme) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(server.veid)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(theme.textTertiary)
                    .frame(width: 76, alignment: .leading)
                TextField(tr("名称", "Name"), text: $vpsEditLabel)
                    .frame(width: 96)
                SecureField(tr("新 API key（留空不换）", "New API key (blank keeps it)"),
                            text: $vpsEditKey)
                    .onSubmit { saveVPSEdit(server.veid) }
            }
            .textFieldStyle(.roundedBorder)
            .font(.system(size: 10, design: .monospaced))
            .disabled(model.vpsSaving)

            HStack(spacing: 6) {
                PillButton(title: model.vpsSaving ? tr("验证中", "Validating") : tr("保存", "Save"),
                           icon: model.vpsSaving ? "hourglass" : "checkmark",
                           theme: theme) { saveVPSEdit(server.veid) }
                    .disabled(model.vpsSaving)
                PillButton(title: tr("取消", "Cancel"), icon: "xmark", theme: theme) {
                    vpsEditingVeid = nil
                }
                .disabled(model.vpsSaving)
            }
        }
    }

    /// 只改名不碰网络；换了 key 就和添加一样，先向 KiwiVM 验证再落盘。
    private func saveVPSEdit(_ veid: String) {
        guard !model.vpsSaving else { return }
        if vpsEditKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            model.onRenameVPS?(veid, vpsEditLabel)
            vpsEditingVeid = nil
            return
        }
        model.onSaveVPS?(veid, vpsEditLabel, vpsEditKey) { saved in
            if saved {
                vpsEditKey = ""
                vpsEditingVeid = nil
            }
        }
    }

    private func saveVPS() {
        guard !model.vpsSaving else { return }
        model.onSaveVPS?(vpsVeidInput, vpsLabelInput, vpsKeyInput) { saved in
            if saved {
                vpsVeidInput = ""
                vpsLabelInput = ""
                vpsKeyInput = ""
            }
        }
    }

    private func clusterSettings(_ theme: PanelTheme) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeOut(duration: 0.2)) {
                    clusterExpanded.toggle()
                }
            } label: {
                settingsHeader(
                    theme,
                    icon: "macbook.and.iphone",
                    color: theme.statusInfo,
                    title: tr("多机同步", "Multi-Host Sync"),
                    subtitle: cluster.enabled
                        ? tr("\(max(1, cluster.nodes.filter { $0.isOnline() }.count))/\(max(1, cluster.nodes.count)) 台在线",
                             "\(max(1, cluster.nodes.filter { $0.isOnline() }.count))/\(max(1, cluster.nodes.count)) online")
                        : tr("独立模式 · 本机数据不会广播", "Standalone · this host's data isn't broadcast"),
                    expanded: clusterExpanded
                )
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(clusterExpanded ? tr("已展开", "Expanded") : tr("已折叠", "Collapsed"))

            if clusterExpanded {
                VStack(alignment: .leading, spacing: 9) {

                    if cluster.enabled {
                        ForEach(cluster.nodes.prefix(6)) { node in
                            clusterNodeRow(node, theme: theme)
                        }

                        if let code = cluster.pairingCode {
                            HStack(spacing: 8) {
                                Image(systemName: "link.badge.plus")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(theme.statusInfo)
                                    .frame(width: 24, height: 24)
                                    .background(Circle().fill(theme.statusInfo.opacity(theme.dark ? 0.18 : 0.09)))
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(tr("在另一台主机输入配对码", "Enter the pairing code on another host"))
                                        .font(.system(size: 9, weight: .semibold, design: .rounded))
                                        .foregroundStyle(theme.textPrimary)
                                    Text(tr("两分钟内有效", "Valid for two minutes"))
                                        .font(.system(size: 8, weight: .medium))
                                        .foregroundStyle(theme.textTertiary)
                                }
                                Spacer()
                                Text(code)
                                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                                    .foregroundStyle(theme.textPrimary)
                                    .textSelection(.enabled)
                                Button {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(code, forType: .string)
                                    pairingCodeCopied = true
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                                        pairingCodeCopied = false
                                    }
                                } label: {
                                    Image(systemName: pairingCodeCopied ? "checkmark" : "doc.on.doc")
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundStyle(pairingCodeCopied
                                            ? theme.statusHealthy
                                            : theme.statusInfo)
                                        .frame(width: 20, height: 20)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .help(tr("复制配对码", "Copy pairing code"))
                                .accessibilityLabel(pairingCodeCopied
                                    ? tr("配对码已复制", "Pairing code copied")
                                    : tr("复制配对码", "Copy pairing code"))
                            }
                            .padding(8)
                            .background(
                                RoundedRectangle(cornerRadius: 9)
                                    .fill(theme.statusInfo.opacity(theme.dark ? 0.10 : 0.05))
                            )
                        }

                        HStack(spacing: 8) {
                            PillButton(
                                title: cluster.syncing ? tr("同步中", "Syncing") : tr("立即同步", "Sync Now"),
                                icon: "arrow.triangle.2.circlepath",
                                theme: theme
                            ) {
                                clusterMessage = tr("正在同步…", "Syncing…")
                                cluster.syncAll { error in
                                    clusterMessage = error.map { tr("同步失败：\($0.localizedDescription)",
                                                                    "Sync failed: \($0.localizedDescription)") }
                                        ?? tr("同步完成", "Sync complete")
                                }
                            }
                            .disabled(cluster.syncing)
                            PillButton(
                                title: cluster.pairingCode == nil ? tr("添加主机", "Add Host") : tr("停止配对", "Stop Pairing"),
                                icon: cluster.pairingCode == nil ? "plus" : "xmark",
                                theme: theme
                            ) {
                                if cluster.pairingCode == nil { cluster.startPairing() }
                                else { cluster.stopPairing() }
                            }
                        }

                        if cluster.nodes.count <= 1 {
                            Divider().opacity(0.35)

                            HStack(spacing: 8) {
                                Image(systemName: "link.badge.plus")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(theme.statusInfo)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(tr("加入已有同步集群", "Join an existing sync cluster"))
                                        .font(.system(size: 9, weight: .semibold, design: .rounded))
                                        .foregroundStyle(theme.textPrimary)
                                    Text(tr("输入另一台主机显示的地址和配对码",
                                            "Enter the address and pairing code shown on another host"))
                                        .font(.system(size: 8, weight: .medium))
                                        .foregroundStyle(theme.textTertiary)
                                }
                            }

                            Text(tr("加入后将替换本机的单节点集群配置，本机历史用量会保留。",
                                    "Joining replaces this host's single-node cluster; its usage history is kept."))
                                .font(.system(size: 8, weight: .medium))
                                .foregroundStyle(theme.statusWarning)
                            clusterJoinFields(theme, buttonTitle: tr("加入已有集群", "Join Existing Cluster"))
                        }

                        if let message = Self.clusterFeedbackMessage(
                            transient: clusterMessage,
                            currentError: cluster.lastError
                        ) {
                            clusterFeedback(
                                message,
                                forceError: clusterMessage == nil && cluster.lastError != nil,
                                theme: theme
                            )
                        }

                        Divider().opacity(0.35)

                        Button {
                            withAnimation(.easeOut(duration: 0.2)) {
                                showClusterAdvanced.toggle()
                            }
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "network")
                                    .font(.system(size: 9, weight: .semibold))
                                Text(tr("高级连接", "Advanced Connection"))
                                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                                Spacer()
                                Text(tr("VPN 手动地址", "Manual VPN address"))
                                    .font(.system(size: 8, weight: .medium))
                                    .foregroundStyle(theme.textTertiary)
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 8, weight: .semibold))
                                    .rotationEffect(.degrees(showClusterAdvanced ? 90 : 0))
                            }
                            .foregroundStyle(theme.textSecondary)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)

                        if showClusterAdvanced {
                            VStack(alignment: .leading, spacing: 6) {
                                HStack(spacing: 6) {
                                    TextField(tr("已配对节点地址，例如 10.1.7.106:8765",
                                                 "Paired node address, e.g. 10.1.7.106:8765"), text: $clusterAddress)
                                        .textFieldStyle(.roundedBorder)
                                        .font(.system(size: 9, design: .monospaced))
                                    PillButton(title: tr("连接", "Connect"), icon: "link", theme: theme) {
                                        let address = clusterAddress
                                        clusterMessage = tr("正在连接 \(address)…", "Connecting to \(address)…")
                                        cluster.addManualEndpoint(address)
                                        cluster.syncAll { error in
                                            if let error {
                                                clusterMessage = tr("连接失败：\(error.localizedDescription)",
                                                                    "Connection failed: \(error.localizedDescription)")
                                            } else {
                                                clusterMessage = tr("已连接并完成同步", "Connected and synced")
                                                clusterAddress = ""
                                            }
                                        }
                                    }
                                    .disabled(clusterAddress.isEmpty)
                                }
                                Text(tr("仅用于已经完成配对、但 Bonjour 无法发现的 VPN 节点。",
                                        "Only for already-paired VPN nodes that Bonjour can't discover."))
                                    .font(.system(size: 8, weight: .medium))
                                    .foregroundStyle(theme.textTertiary)
                            }
                            .transition(.opacity)
                        }

                        DestructiveButton(
                            title: tr("离开同步集群", "Leave Sync Cluster"),
                            icon: "rectangle.portrait.and.arrow.right",
                            theme: theme,
                            hint: tr("停止与其他主机同步，本机历史数据会保留",
                                     "Stops syncing with other hosts; this host's history is kept")
                        ) { showLeaveClusterConfirmation = true }
                    } else {
                        WideButton(title: tr("创建同步集群", "Create Sync Cluster"), icon: "plus.circle", theme: theme) {
                            clusterMessage = cluster.createCluster()
                                ? tr("同步集群已创建，可在此生成配对码", "Sync cluster created; you can generate a pairing code here")
                                : tr("创建失败：集群凭据写入失败，请重试", "Creation failed: could not write cluster credentials, please try again")
                        }

                        Divider().opacity(0.4)

                        clusterJoinFields(theme, buttonTitle: tr("加入同步集群", "Join Sync Cluster"))
                    }

                    if !cluster.enabled, let message = clusterMessage ?? cluster.lastError {
                        clusterFeedback(
                            message,
                            forceError: clusterMessage == nil && cluster.lastError != nil,
                            theme: theme
                        )
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
                .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(theme)
        .alert(tr("离开同步集群？", "Leave sync cluster?"), isPresented: $showLeaveClusterConfirmation) {
            Button(tr("取消", "Cancel"), role: .cancel) {}
            Button(tr("离开", "Leave"), role: .destructive) { cluster.leaveCluster() }
        } message: {
            Text(tr("本机将停止同步；本地采集数据不会删除。重新加入需要新的配对码。",
                    "This host will stop syncing; locally collected data isn't deleted. Rejoining needs a new pairing code."))
        }
    }

    private func clusterNodeRow(_ node: ClusterNodeRecord, theme: PanelTheme) -> some View {
        let local = node.nodeID == cluster.nodeID
        let online = node.isOnline()
        let expanded = expandedNodeID == node.nodeID
        return VStack(alignment: .leading, spacing: 6) {
            Button {
                Log.user(expanded ? "collapse cluster node detail" : "expand cluster node detail")
                withAnimation(.easeOut(duration: 0.16)) {
                    expandedNodeID = expanded ? nil : node.nodeID
                }
            } label: {
                clusterNodeSummary(node, local: local, online: online,
                                   expanded: expanded, theme: theme)
            }
            .buttonStyle(.plain)
            .accessibilityValue(expanded ? tr("已展开", "Expanded") : tr("已折叠", "Collapsed"))

            if expanded {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Self.clusterNodeDetails(node, isLocal: local,
                                                    localEndpoint: cluster.localEndpoint,
                                                    peers: cluster.discoveredPeers,
                                                    stun: local ? model.natObservation : nil,
                                                    stunUnavailable: local && model.natUnavailable),
                            id: \.label) { row in
                        HStack(alignment: .top, spacing: 6) {
                            Text(row.label)
                                .font(.system(size: 8, weight: .medium))
                                .foregroundStyle(theme.textTertiary)
                                .frame(width: 54, alignment: .leading)
                            Text(row.value)
                                .font(.system(size: 8, weight: .semibold, design: .rounded))
                                .foregroundStyle(theme.textSecondary)
                                .textSelection(.enabled)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer(minLength: 0)
                        }
                    }
                }
                .padding(.leading, 34)
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 9)
                .fill(theme.glassBackground.opacity(theme.dark ? 0.72 : 0.58))
        )
    }

    private func clusterNodeSummary(_ node: ClusterNodeRecord, local: Bool, online: Bool,
                                    expanded: Bool, theme: PanelTheme) -> some View {
        HStack(spacing: 8) {
            Image(systemName: local ? "laptopcomputer" : "desktopcomputer")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(online ? theme.statusInfo : theme.textTertiary)
                .frame(width: 26, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 7)
                        .fill((online ? theme.statusInfo : theme.textTertiary).opacity(theme.dark ? 0.16 : 0.08))
                )
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(node.name)
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundStyle(theme.textPrimary)
                        .lineLimit(1)
                    if local {
                        Text(tr("本机", "This Host"))
                            .font(.system(size: 7, weight: .bold, design: .rounded))
                            .foregroundStyle(theme.textSecondary)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(theme.glassBackground))
                    }
                }
                Text(local
                     ? tr("本机节点", "This node")
                     : node.lastSyncAt.map { tr("同步于 \($0.formatted(date: .omitted, time: .shortened))",
                                               "Synced at \($0.formatted(date: .omitted, time: .shortened))") }
                        ?? (online ? tr("已连接，等待首次同步", "Connected, awaiting first sync")
                                   : tr("尚未同步", "Not synced yet")))
                    .font(.system(size: 8, weight: .medium))
                    .foregroundStyle(theme.textTertiary)
            }
            Spacer(minLength: 6)
            StateBadge(
                text: online ? tr("在线", "Online") : tr("离线", "Offline"),
                color: online ? theme.statusHealthy : theme.textTertiary
            )
            Image(systemName: "chevron.down")
                .font(.system(size: 7, weight: .bold))
                .foregroundStyle(theme.textTertiary)
                .rotationEffect(.degrees(expanded ? 0 : -90))
        }
        .contentShape(Rectangle())
    }


    // MARK: - Nebula overlay

    /// 微秒是存储单位，因为到同网段主机的 overlay 往返不到一毫秒；亚毫秒保留两位小数，
    /// 否则它们会全都渲染成同一个 "0ms"。
    static func meshLatency(_ micros: Int) -> String {
        let millis = Double(micros) / 1000
        return millis < 10 ? String(format: "%.2fms", millis) : String(format: "%.0fms", millis)
    }

    /// 说出依据而不只是结论：判「隧道坏」是在断言别人的机器没问题，
    /// 而这个断言只因为 lighthouse 够得着本机够不着的那台才立得住。
    static func meshStateText(_ host: MeshHostView) -> String {
        switch host.state {
        case .online: return tr("在线", "online")
        case .tunnelDown:
            guard let rtt = host.lighthouseRttUs else { return tr("隧道未通", "tunnel down") }
            return tr("隧道未通（lighthouse \(meshLatency(rtt))）",
                      "tunnel down (lighthouse \(meshLatency(rtt)))")
        case .offline: return tr("离线", "offline")
        case .unreachable: return tr("不可达，原因未知", "unreachable, cause unknown")
        }
    }

    static func meshStateColor(_ state: MeshState, theme: PanelTheme) -> Color {
        switch state {
        case .online: return theme.statusHealthy
        case .offline: return theme.textTertiary
        case .tunnelDown, .unreachable: return theme.statusWarning
        }
    }

    /// nebula overlay：每一台有证书的设备，以及本机能到达哪些。
    /// 与多机同步刻意分开——那是另一批机器，回答的是另一个问题。
    ///
    /// 卡片只回答「现在几台通」，点开在面板内翻到历史那一页，和点 Claude 卡片进用量
    /// 统计是同一个动作。
    private func meshCard(_ theme: PanelTheme) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                Log.user("open nebula overlay")
                withAnimation(.easeOut(duration: 0.2)) { model.showMesh = true }
            } label: {
                // 紧凑头部：与主列表里的 Agent 会话、电子纸屏幕保持同一套样式。
                // settingsHeader 那种 26pt 彩色圆加副标题是设置页的样式，混进来会让
                // 这张卡比邻居高出一截。
                HStack(spacing: 6) {
                    Image(systemName: "network")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(theme.textSecondary)
                    Text(tr("Nebula 网络", "Nebula Overlay"))
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(theme.textPrimary)
                    Spacer()
                    StateBadge(
                        text: "\(mesh.hosts.filter { $0.state == .online }.count)/\(mesh.hosts.count)",
                        color: mesh.hosts.isEmpty || mesh.hosts.contains { $0.state != .online }
                            ? theme.statusWarning : theme.statusHealthy
                    )
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(theme.textTertiary)
                }
                .padding(.horizontal, 12)
                .padding(.top, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(tr("Nebula 网络", "Nebula Overlay"))
            .accessibilityHint(tr("展开完整的网格视图", "Opens the full overlay view"))

            VStack(alignment: .leading, spacing: 5) {
                Text(Self.meshSubtitle(
                    total: mesh.hosts.count,
                    reachable: mesh.hosts.filter { $0.state == .online }.count,
                    updatedAt: mesh.updatedAt
                ))
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(theme.textTertiary)
                if !mesh.icmpAvailable {
                    meshNotice(tr("无法打开 ICMP socket，本机可达性暂时测不了",
                                  "No ICMP socket: reachability unavailable on this host"),
                               theme: theme)
                }
                if let notice = Self.meshRosterNotice(configured: mesh.configured,
                                                      reachable: mesh.lighthouseReachable) {
                    meshNotice(notice, theme: theme)
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 5)
            .padding(.bottom, 12)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(theme)
    }


    /// 名册缺席的两种原因要分开说：没配地址是「去填一个」，连不上是「只能等，先看旧的」。
    /// 合成一句「lighthouse 不可达」会把从没发出过请求的情形说成网络故障。
    static func meshRosterNotice(configured: Bool, reachable: Bool) -> String? {
        guard configured else {
            return tr("未配置 lighthouse 地址，取不到设备清单",
                      "No lighthouse address: no roster to show")
        }
        return reachable ? nil : tr("lighthouse 不可达，显示的是上一次的名册",
                                    "Lighthouse unreachable: showing the last known roster")
    }

    /// 陈旧必须可见。一个 30 秒前的 221ms 和刚测出来的 221ms 长得一模一样，而这块
    /// 面板是用来判断「现在通不通」的——不写出数据年龄，旧数据就会冒充实时数据。
    static func meshSubtitle(total: Int, reachable: Int, updatedAt: Date?,
                             now: Date = Date()) -> String {
        let head = tr("\(total) 台设备 · \(reachable) 台本机可达",
                      "\(total) devices · \(reachable) reachable from here")
        guard let updatedAt else {
            return head + tr(" · 尚未探测", " · not probed yet")
        }
        let age = Int(max(0, now.timeIntervalSince(updatedAt)))
        let ago = age < 60
            ? tr("\(age) 秒前", "\(age)s ago")
            : tr("\(age / 60) 分钟前", "\(age / 60)m ago")
        return head + " · " + ago
    }

    /// 悬停时说明这一个桶，否则说明整段窗口。两者都要标出丢样，因为「平均 1.4ms」
    /// 配上「三分之一探测没回来」是完全不同的一件事。
    static func meshHistorySummary(points: [MeshBucketPoint],
                                   hovered: MeshBucketPoint?) -> String {
        if let hovered {
            let time = DateFormatter.localizedString(from: hovered.bucketAt,
                                                     dateStyle: .none, timeStyle: .short)
            guard let low = hovered.rttMinUs, let high = hovered.rttMaxUs else {
                return tr("\(time) · 全部丢失（\(hovered.samples) 次探测）",
                          "\(time) · all lost (\(hovered.samples) probes)")
            }
            let range = low == high
                ? meshLatency(low)
                : "\(meshLatency(low))–\(meshLatency(high))"
            guard hovered.lostSamples > 0 else {
                return tr("\(time) · \(range)", "\(time) · \(range)")
            }
            return tr("\(time) · \(range) · 丢 \(hovered.lostSamples)/\(hovered.samples)",
                      "\(time) · \(range) · \(hovered.lostSamples)/\(hovered.samples) lost")
        }
        let samples = points.reduce(0) { $0 + $1.samples }
        guard samples > 0 else { return tr("暂无历史数据", "No history yet") }
        let lost = points.reduce(0) { $0 + $1.lostSamples }
        let lows = points.compactMap(\.rttMinUs)
        let highs = points.compactMap(\.rttMaxUs)
        guard let low = lows.min(), let high = highs.max() else {
            return tr("\(samples) 次探测全部丢失", "all \(samples) probes lost")
        }
        let head = tr("\(meshLatency(low))–\(meshLatency(high)) · \(samples) 次探测",
                      "\(meshLatency(low))–\(meshLatency(high)) · \(samples) probes")
        guard lost > 0 else { return head }
        return head + tr(" · 丢 \(lost)", " · \(lost) lost")
    }

    private func meshNotice(_ text: String, theme: PanelTheme) -> some View {
        Text(text)
            .font(.system(size: 8, weight: .medium))
            .foregroundStyle(theme.statusWarning)
    }

    struct ClusterNodeDetailRow: Equatable {
        let label: String
        let value: String
    }

    /// 节点详情：连接地址优先用已记录的 endpoint，其次用 Bonjour 发现结果，本机则用局域网地址
    /// 陈述事实而非好坏：保端口是端口争抢的前提条件，被改写反而不参与争抢，
    /// 所以两种结果都不加警示色，只有判据本身失效时才需要提醒。
    static func clusterNatDetail(_ value: StunObservation?, unavailable: Bool) -> String? {
        guard let value else {
            return unavailable
                ? tr("STUN 不可达，端口判据暂时失效",
                     "STUN unreachable, port test unavailable")
                : nil
        }
        return value.portPreserved
            ? tr("\(value.externalEndpoint) · 保端口，在争抢池内",
                 "\(value.externalEndpoint) · port-preserving, in contention")
            : tr("\(value.externalEndpoint) · 端口被改写，不参与争抢",
                 "\(value.externalEndpoint) · port rewritten, not in contention")
    }

    static func clusterNodeDetails(_ node: ClusterNodeRecord, isLocal: Bool,
                                   localEndpoint: String?,
                                   peers: [DiscoveredClusterPeer],
                                   stun: StunObservation? = nil,
                                   stunUnavailable: Bool = false) -> [ClusterNodeDetailRow] {
        let address = isLocal
            ? localEndpoint
            : (node.endpoint ?? peers.first { $0.nodeID == node.nodeID }?.endpoint)
        var rows = [
            ClusterNodeDetailRow(label: tr("连接地址", "Address"),
                                 value: address ?? tr("未知", "Unknown")),
            ClusterNodeDetailRow(label: tr("节点 ID", "Node ID"), value: node.nodeID)
        ]
        // 出口 NAT 是本机自己的属性，只挂在本机这一行上
        if isLocal, let nat = Self.clusterNatDetail(stun, unavailable: stunUnavailable) {
            rows.append(ClusterNodeDetailRow(label: tr("出口 NAT", "Egress NAT"), value: nat))
        }
        guard !isLocal else { return rows }
        rows.append(ClusterNodeDetailRow(
            label: tr("最后在线", "Last seen"),
            value: node.lastSeenAt.map(Self.clusterTimestamp) ?? tr("未知", "Unknown")
        ))
        rows.append(ClusterNodeDetailRow(
            label: tr("最后同步", "Last sync"),
            value: node.lastSyncAt.map(Self.clusterTimestamp) ?? tr("尚未同步", "Not synced yet")
        ))
        return rows
    }

    private static func clusterTimestamp(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }

    private func clusterFeedback(_ message: String, forceError: Bool,
                                 theme: PanelTheme) -> some View {
        let lower = message.lowercased()
        let failed = forceError
            || ["失败", "错误", "无法", "不属于", "尚无"].contains { message.contains($0) }
            || ["fail", "error", "cannot", "could not", "not part of", "no pairing"]
                .contains { lower.contains($0) }
        let working = message.contains("正在") || message.hasSuffix("…")
        let color = failed
            ? theme.statusCritical
            : working ? theme.statusInfo : theme.statusHealthy
        let icon = failed ? "exclamationmark.circle.fill"
            : working ? "arrow.triangle.2.circlepath" : "checkmark.circle.fill"
        return HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 9, weight: .semibold))
            Text(message)
                .font(.system(size: 8, weight: .semibold, design: .rounded))
                .lineLimit(3)
            Spacer(minLength: 0)
        }
        .foregroundStyle(color)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8).fill(color.opacity(theme.dark ? 0.14 : 0.08)))
        .accessibilityLabel(message)
    }

    static func clusterFeedbackMessage(transient: String?, currentError: String?) -> String? {
        guard let transient else { return currentError }
        if transient.hasPrefix("正在") || transient.hasSuffix("…") { return transient }

        if transient.hasPrefix("同步失败：") || transient.hasPrefix("Sync failed:")
            || transient == "同步完成" || transient == "Sync complete" {
            return currentError.map { tr("同步失败：\($0)", "Sync failed: \($0)") }
                ?? ((transient == "同步完成" || transient == "Sync complete") ? transient : nil)
        }
        if transient.hasPrefix("连接失败：") || transient.hasPrefix("Connection failed:")
            || transient == "已连接并完成同步" || transient == "Connected and synced" {
            return currentError.map { tr("连接失败：\($0)", "Connection failed: \($0)") }
                ?? ((transient == "已连接并完成同步" || transient == "Connected and synced") ? transient : nil)
        }
        return transient
    }

    static func preferredPairingPeer(in peers: [DiscoveredClusterPeer]) -> DiscoveredClusterPeer? {
        peers.first { $0.pairable && $0.pairingCompatible }
            ?? peers.first { $0.pairable }
    }

    @ViewBuilder
    private func clusterJoinFields(_ theme: PanelTheme, buttonTitle: String) -> some View {
        TextField(tr("集群主机地址，例如 macbook.local:8765",
                     "Cluster host address, e.g. macbook.local:8765"), text: $clusterAddress)
            .textFieldStyle(.roundedBorder)
            .font(.system(size: 10, design: .monospaced))
            .onSubmit { joinClusterFromFields() }
        TextField(tr("配对码，例如 ABCD-EFGH-JKMN-PQRS（填满后自动加入）",
                     "Pairing code, e.g. ABCD-EFGH-JKMN-PQRS (auto-joins once complete)"), text: $clusterCode)
            .textFieldStyle(.roundedBorder)
            .font(.system(size: 10, design: .monospaced))
            .onSubmit { joinClusterFromFields() }
            .onChange(of: clusterCode) { value in
                let cleaned = String(
                    value.uppercased()
                        .filter { $0.isLetter || $0.isNumber || $0 == "-" }
                        .prefix(19)
                )
                if cleaned != value {
                    clusterCode = cleaned
                    return
                }
                if ClusterCrypto.normalizedPairingCode(cleaned) != nil,
                   !clusterAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    joinClusterFromFields()
                }
            }
        Text(tr("在集群主机点击“添加主机”生成配对码；验证码有效期为两分钟。",
                "Click “Add Host” on the cluster host to generate a pairing code; it's valid for two minutes."))
            .font(.system(size: 8, weight: .medium))
            .foregroundStyle(theme.textTertiary)
        if let peer = Self.preferredPairingPeer(in: cluster.discoveredPeers) {
            if peer.pairingCompatible {
                Button(tr("使用已发现的 \(peer.name)", "Use discovered \(peer.name)")) {
                    clusterAddress = peer.endpoint
                    if ClusterCrypto.normalizedPairingCode(clusterCode) != nil { joinClusterFromFields() }
                }
                .buttonStyle(.plain)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(theme.textSecondary)
            } else {
                Text(tr("发现 \(peer.name)，但其版本过旧，无法配对；请先把它升级到最新版",
                        "Found \(peer.name), but its version is too old to pair; please update it to the latest version first"))
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(theme.statusWarning)
            }
        }
        WideButton(title: buttonTitle, icon: "link.badge.plus", theme: theme) {
            joinClusterFromFields()
        }
        .disabled(model.busy)
    }

    private func joinClusterFromFields() {
        guard !model.busy else { return }
        model.busy = true
        clusterMessage = tr("正在安全配对…", "Securely pairing…")
        cluster.joinCluster(endpoint: clusterAddress, code: clusterCode) { error in
            model.busy = false
            if let error {
                clusterMessage = tr("配对失败：\(error.localizedDescription)",
                                    "Pairing failed: \(error.localizedDescription)")
            } else {
                clusterMessage = tr("配对成功，正在同步其他主机的历史用量",
                                    "Paired · syncing other hosts' usage history")
                clusterAddress = ""
                clusterCode = ""
            }
        }
    }

    private func logSettings(_ theme: PanelTheme) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            settingsHeader(theme, icon: "doc.text.fill", color: theme.textTertiary,
                           title: tr("日志", "Logs"), subtitle: tr("查看桥接应用运行日志", "View the bridge app's runtime logs"))
            WideButton(title: tr("打开日志文件", "Open Log File"), icon: "doc.text", theme: theme) {
                let url = Log.fileURL()
                Log.user("open log file in Console \(url.path)")
                Log.flush()
                if NSWorkspace.shared.open(url) {
                    model.settingsMessage = tr("日志文件：\(url.path)", "Log file: \(url.path)")
                } else {
                    Log.warning("Console failed to open log file \(url.path)", category: "user")
                    model.settingsMessage = tr("无法使用 Console 打开日志文件：\(url.path)",
                                               "Could not open the log file with Console: \(url.path)")
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
                           title: tr("关于", "About"), subtitle: tr("版本 \(AppInfo.version)", "Version \(AppInfo.version)"))
            WideButton(title: tr("在 GitHub 查看", "View on GitHub"), icon: "link", theme: theme) {
                Log.user("open project page on GitHub")
                NSWorkspace.shared.open(AppInfo.repoURL)
            }
            Text(tr("在 GitHub 反馈问题或参与贡献", "Report issues or contribute on GitHub"))
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(theme.textTertiary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(theme)
    }

    private func updateSettings(_ theme: PanelTheme) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeOut(duration: 0.2)) {
                    updatesExpanded.toggle()
                }
            } label: {
                settingsHeader(theme, icon: "arrow.down.circle.fill", color: theme.statusHealthy,
                               title: tr("软件更新", "Software Update"),
                               subtitle: tr("当前版本 \(updater.currentVersion)", "Current version \(updater.currentVersion)"),
                               expanded: updatesExpanded)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if updatesExpanded {
                VStack(alignment: .leading, spacing: 9) {
                    UpdateCheckButton(checking: updater.isChecking, theme: theme) {
                        Log.user("check for application updates")
                        updater.check()
                    }
                    .disabled(updater.isChecking || updater.isInstalling)

                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        if updater.isChecking {
                            ProgressView()
                                .controlSize(.small)
                                .scaleEffect(0.7)
                                .frame(width: 10, height: 10)
                        } else {
                            Image(systemName: updateStatusIcon)
                                .font(.system(size: 8, weight: .semibold))
                        }
                        Text(updateStatusText)
                            .font(.system(size: 9, weight: .semibold))
                            .lineLimit(2)
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(updateStatusColor(theme))

                    if updater.state == .updateAvailable {
                        if updater.canInstallAvailableUpdate {
                            WideButton(title: updateInstallTitle, icon: "arrow.triangle.2.circlepath", theme: theme) {
                                updater.installAvailableUpdate()
                            }
                            .disabled(updater.isInstalling)
                        }
                        if case let .failed(message) = updater.installState {
                            Text(message)
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(theme.statusWarning)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        // 不能自动安装、或自动安装失败时，保留手动下载入口。
                        if !updater.canInstallAvailableUpdate || updateInstallFailed {
                            WideButton(title: tr("下载 v\(updater.latestVersion ?? "最新版") DMG",
                                                 "Download v\(updater.latestVersion ?? "latest") DMG"),
                                       icon: "arrow.down.to.line.compact", theme: theme) {
                                updater.openAvailableUpdate()
                            }
                        }
                    }

                    if let lastCheckedAt = updater.lastCheckedAt {
                        HStack(spacing: 4) {
                            Image(systemName: "clock.fill").font(.system(size: 8))
                            Text(tr("上次检查：\(lastCheckedAt.formatted(date: .abbreviated, time: .shortened))",
                                    "Last checked: \(lastCheckedAt.formatted(date: .abbreviated, time: .shortened))"))
                                .font(.system(size: 9, weight: .medium))
                        }
                        .foregroundStyle(theme.textTertiary)
                    }

                    Divider().opacity(0.4)

                    updateToggle(
                        title: tr("自动检查更新", "Check for updates automatically"),
                        subtitle: tr("打开菜单时定期检查 GitHub Releases", "Periodically check GitHub Releases when the menu opens"),
                        isOn: Binding(
                            get: { updater.automaticallyChecks },
                            set: { updater.setAutomaticallyChecks($0) }
                        ),
                        theme: theme
                    )
                    updateToggle(
                        title: tr("包含测试版本", "Include pre-releases"),
                        subtitle: tr("同时检查 GitHub prerelease 版本", "Also check GitHub prerelease versions"),
                        isOn: Binding(
                            get: { updater.includesPrereleases },
                            set: { updater.setIncludesPrereleases($0) }
                        ),
                        theme: theme
                    )
                    // 安装期间改偏好不会触发重新检查，失败后会继续推荐已取消订阅的版本。
                    .disabled(updater.isInstalling)
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
                .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(theme)
    }

    private func updateToggle(title: String, subtitle: String,
                              isOn: Binding<Bool>, theme: PanelTheme) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(theme.textPrimary)
                Text(subtitle)
                    .font(.system(size: 8, weight: .medium))
                    .foregroundStyle(theme.textTertiary)
            }
            Spacer()
            Toggle("", isOn: isOn)
                .toggleStyle(.switch)
                .tint(theme.statusHealthy)
                .scaleEffect(0.78)
                .labelsHidden()
        }
    }

    private var updateStatusText: String {
        if updater.isChecking { return tr("正在检查 GitHub Releases…", "Checking GitHub Releases…") }
        switch updater.state {
        case .idle: return tr("尚未检查更新", "Not checked yet")
        case .upToDate: return tr("已是最新版", "Up to date")
        case .updateAvailable: return tr("发现新版本 v\(updater.latestVersion ?? "")", "New version v\(updater.latestVersion ?? "") available")
        case let .failed(message): return tr("检查失败：\(message)", "Check failed: \(message)")
        }
    }

    private var updateInstallFailed: Bool {
        if case .failed = updater.installState { return true }
        return false
    }

    private var updateInstallTitle: String {
        switch updater.installState {
        case .downloading: return tr("正在下载…", "Downloading…")
        case .verifying: return tr("正在校验…", "Verifying…")
        case .installing: return tr("正在安装…", "Installing…")
        case .idle, .failed:
            return tr("更新到 v\(updater.latestVersion ?? "最新版") 并重启",
                      "Update to v\(updater.latestVersion ?? "latest") and Relaunch")
        }
    }

    private var updateStatusIcon: String {
        switch updater.state {
        case .idle: return "clock.fill"
        case .upToDate: return "checkmark.circle.fill"
        case .updateAvailable: return "arrow.down.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }

    private func updateStatusColor(_ theme: PanelTheme) -> Color {
        switch updater.state {
        case .upToDate, .updateAvailable: return theme.statusHealthy
        case .failed: return theme.statusWarning
        case .idle: return theme.textTertiary
        }
    }

    private func settingsHeader(_ theme: PanelTheme, icon: String, color: Color,
                                title: String, subtitle: String,
                                expanded: Bool? = nil) -> some View {
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
            if let expanded {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(theme.textTertiary)
                    .rotationEffect(.degrees(expanded ? 90 : 0))
            }
        }
    }

    private func footer(_ theme: PanelTheme) -> some View {
        HStack(spacing: 8) {
            Spacer()
            CircleIconButton(icon: model.showSettings ? "xmark" : "gearshape.fill", theme: theme) {
                Log.user(model.showSettings ? "close settings" : "open settings")
                withAnimation(.easeOut(duration: 0.2)) { model.showSettings.toggle() }
            }
            CircleIconButton(icon: "power", theme: theme) {
                Log.user("quit application")
                Log.flush()
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
                .foregroundStyle(hovering ? theme.accentForeground : theme.textSecondary)
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

enum UsagePresentation {
    enum NoticeKind: Equatable {
        case limit
        case cachedRateLimit
        case failure
    }

    struct Notice: Equatable {
        let kind: NoticeKind
        let text: String
    }

    private static let freshCacheAge: TimeInterval = 10 * 60

    static func missingPrimaryText(_ status: AgentStatus) -> String {
        if status.weekly.percent != nil { return tr("当前无活跃的 5 小时窗口", "No active 5h window") }
        if isRateLimited(status.error) { return tr("用量更新受限，稍后自动重试", "Usage updates are limited, retrying later") }
        return status.error ?? tr("暂无用量数据", "No usage data")
    }

    static func freshnessText(_ status: AgentStatus, now: Date = Date()) -> String? {
        guard let fetchedAt = status.usageFetchedAt else { return nil }
        let age = max(0, Int(now.timeIntervalSince(fetchedAt)))
        let relative = age < 5 ? tr("刚刚", "just now") : tr("\(PreviewPopoverController.formatAge(age))前", "\(PreviewPopoverController.formatAge(age)) ago")
        return status.usageCached ? tr("缓存 · \(relative)", "Cached · \(relative)") : tr("\(relative)更新", "Updated \(relative)")
    }

    static func notice(_ status: AgentStatus, now: Date = Date(),
                       timeZone: TimeZone = .current) -> Notice? {
        guard let error = status.error else { return nil }
        guard status.primary.percent != nil || status.weekly.percent != nil else { return nil }
        guard isRateLimited(error) else {
            return Notice(kind: .failure, text: tr("更新失败 · \(error)", "Update failed · \(error)"))
        }

        let exceededWindows = [status.primary, status.weekly].filter {
            ($0.percent ?? 0) >= 100
        }
        if !exceededWindows.isEmpty {
            let resetAt = exceededWindows.compactMap { window -> Date? in
                if let resetAt = window.resetAt { return resetAt }
                return window.resetMinutes.map { now.addingTimeInterval(TimeInterval($0 * 60)) }
            }.min()
            let suffix = resetAt.map { tr(" · \(clockTime($0, timeZone: timeZone)) 重置", " · resets at \(clockTime($0, timeZone: timeZone))") } ?? ""
            return Notice(kind: .limit, text: tr("已达到用量上限\(suffix)", "Usage limit reached\(suffix)"))
        }

        if status.usageCached,
           let fetchedAt = status.usageFetchedAt,
           max(0, now.timeIntervalSince(fetchedAt)) <= freshCacheAge {
            return nil
        }
        let text = status.usageCached
            ? tr("用量更新受限 · 显示缓存", "Usage updates limited · showing cache")
            : tr("用量更新受限 · 稍后自动重试", "Usage updates limited · retrying later")
        return Notice(kind: .cachedRateLimit, text: text)
    }

    static func isRateLimited(_ error: String?) -> Bool {
        error?.contains("429") == true
    }

    private static func clockTime(_ date: Date, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }
}

struct ProviderCard: View {
    let name: String
    let pet: [String]
    let accent: Color
    let status: AgentStatus
    let theme: PanelTheme
    var cost: CostSummary?
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
                    Text(tr("5 小时", "5h"))
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(theme.textSecondary)
                }
                UsageBar(percent: percent, theme: theme)
                resetLine(status.primary.resetMinutes)
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text("—")
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                        .foregroundStyle(theme.textTertiary)
                    Spacer()
                    Text(tr("5 小时", "5h"))
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(theme.textSecondary)
                }
                // 没有活跃窗口时也要占住进度条那一格。两张卡并排，这一段短了
                // 一条进度条的高度，下面的 7 天进度条就会左右错开——一眼看得出来。
                UsageBar(percent: 0, theme: theme).hidden()
                footnote(UsagePresentation.missingPrimaryText(status))
            }
            if let weekly = status.weekly.percent {
                HStack {
                    Text(tr("7 天", "7d"))
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
            // 模型作用域的周限额挂在总周额度下面：它们是套在里面的子限额，
            // 「总量还宽裕但 Opus 已经打满」必须能一眼看出来。
            ForEach(status.scopedLimits, id: \.id) { limit in
                if let percent = limit.window.percent {
                    HStack {
                        Text(limit.title)
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(theme.textSecondary)
                            .lineLimit(1)
                        Spacer()
                        Text("\(Int(percent))%")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(theme.textPrimary)
                            .contentTransition(.numericText())
                    }
                    UsageBar(percent: percent, theme: theme)
                    resetLine(limit.window.resetMinutes)
                }
            }
            if status.extraUsage != nil || status.creditBalance != nil {
                extraUsageSection(status.extraUsage, balance: status.creditBalance)
            }
            if let notice = UsagePresentation.notice(status) {
                HStack(spacing: 3) {
                    Image(systemName: notice.kind == .limit
                          ? "hourglass"
                          : "exclamationmark.triangle.fill")
                        .font(.system(size: 7))
                    Text(notice.text)
                        .font(.system(size: 8, weight: .semibold))
                        .lineLimit(2)
                }
                .foregroundStyle(notice.kind == .failure
                                 ? theme.statusWarning
                                 : theme.textSecondary)
                .help(status.error ?? notice.text)
            }
            if let freshness = UsagePresentation.freshnessText(status) {
                HStack(spacing: 3) {
                    Image(systemName: status.usageCached ? "archivebox.fill" : "clock.fill")
                        .font(.system(size: 7))
                    Text(freshness)
                        .font(.system(size: 8, weight: .medium))
                }
                .foregroundStyle(status.usageCached ? theme.statusWarning : theme.textTertiary)
            }
            if let cost, !cost.isEmpty {
                costSection(cost)
            } else if status.tokensToday > 0 {
                HStack(spacing: 3) {
                    Image(systemName: "number.circle.fill")
                        .font(.system(size: 7))
                    Text(tr("今日 \(UsageFormat.tokens(status.tokensToday)) tokens", "Today \(UsageFormat.tokens(status.tokensToday)) tokens"))
                        .font(.system(size: 9, weight: .medium))
                }
                .foregroundStyle(theme.textSecondary)
            }
            if status.tokensToday > 0 {
                ForEach(status.modelUsageToday, id: \.model) { usage in
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
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .glassCard(theme)
        .scaleEffect(hovering ? 1.015 : 1.0)
        .animation(.easeOut(duration: 0.15), value: hovering)
        .onHover { hovering = $0 }
        .contentShape(RoundedRectangle(cornerRadius: 14))
        .onTapGesture(perform: onOpenStats)
    }

    /// 额外用量：订阅额度之外按量计费的池子，以及账号上还剩多少积分。
    /// 数已经换算好、单位也跟着数走，这里只负责显示。
    ///
    /// 两者可以各自单独出现：有的账号只有积分余额没有月度上限，反过来也有。
    private func extraUsageSection(_ extra: ExtraUsage?, balance: Double?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Divider().opacity(0.3)
            HStack {
                Text(tr("额外用量", "Extra usage"))
                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                    .foregroundStyle(theme.textPrimary)
                Spacer()
                if let extra {
                    Text(tr("已用 \(Int(extra.percent))%", "\(Int(extra.percent))% used"))
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(theme.textSecondary)
                }
            }
            if let extra {
                UsageBar(percent: extra.percent, theme: theme)
                let pair = UsageFormat.amountPair(extra.used, extra.limit, unit: extra.unit)
                Text(tr("本月：\(pair)", "This month: \(pair)"))
                    .font(.system(size: 8, weight: .medium))
                    .foregroundStyle(theme.textTertiary)
            }
            if let balance {
                Text(tr("积分余额：\(UsageFormat.credits(balance))",
                        "Credit balance: \(UsageFormat.credits(balance))"))
                    .font(.system(size: 8, weight: .medium))
                    .foregroundStyle(theme.textTertiary)
            }
        }
    }

    /// 成本。是「同样的量走官方 API 要花多少」的折算，不是账单——订阅额度内
    /// 并不按 token 收费，措辞必须守住这个口径。
    private func costSection(_ cost: CostSummary) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Divider().opacity(0.3)
            HStack(spacing: 3) {
                Text(tr("成本", "Cost"))
                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                    .foregroundStyle(theme.textPrimary)
                Text(tr("API 等价", "API-equivalent"))
                    .font(.system(size: 7, weight: .medium))
                    .foregroundStyle(theme.textTertiary)
                Spacer()
                if cost.hasUnpriced {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 7))
                        .foregroundStyle(theme.statusWarning)
                        .help(tr("有模型没有定价，未计入金额", "Some models have no pricing and are not counted"))
                }
            }
            costLine(tr("今日", "Today"), cost: cost.todayCost, tokens: cost.todayTokens)
            costLine(tr("近 30 天", "Last 30 days"), cost: cost.monthCost, tokens: cost.monthTokens)
        }
    }

    private func costLine(_ label: String, cost: Double, tokens: Int) -> some View {
        HStack(spacing: 3) {
            Text("\(label):")
                .font(.system(size: 8, weight: .medium))
                .foregroundStyle(theme.textTertiary)
            Text("\(UsageStats.costText(cost)) · \(UsageFormat.tokens(tokens)) tokens")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(theme.textSecondary)
            Spacer(minLength: 0)
        }
    }

    private func resetLine(_ minutes: Int?) -> some View {
        footnote(minutes.map { tr("\(MenuBarController.formatMinutes($0)) 后重置", "resets in \(MenuBarController.formatMinutes($0))") } ?? tr("无活跃窗口", "No active window"))
    }

    /// 进度条底下那行小字。重置时间和「没有活跃窗口」都走这里：它们是同一类信息，
    /// 也必须是同一个高度，否则两张卡的 7 天区块对不齐。
    private func footnote(_ text: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: "clock.fill").font(.system(size: 7))
            Text(text)
                .font(.system(size: 8, weight: .medium))
                .lineLimit(2)
        }
        .foregroundStyle(theme.textTertiary)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var stateText: String {
        if status.needsInput { return tr("等输入", "Needs Input") }
        switch status.state {
        case "working": return tr("运行中", "Working")
        case "idle": return tr("空闲", "Idle")
        default: return tr("离线", "Offline")
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

struct UsageBar: View {
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

struct StateBadge: View {
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
            .foregroundStyle(hovering ? theme.accentForeground : theme.textSecondary)
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
            .foregroundStyle(hovering ? theme.accentForeground : theme.textSecondary)
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

/// 列表行末尾的图标按钮。
///
/// 与 `DestructiveButton` 分开是因为它们回答的不是同一个问题：那个是设置页里一段
/// 独立操作的主按钮，理应显眼且占满半行；这个挂在一行内容的末尾，行的主体是内容
/// 本身，动作要退到后面去。破坏性的提示交给悬停时的红色和之后的二次确认，常态
/// 不喊——一列常驻的红按钮会让整节看起来像是在推销删除。
private struct RowIconButton: View {
    let icon: String
    let theme: PanelTheme
    let label: String
    let hint: String
    var hoverColor: Color?
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        let accent = hoverColor ?? theme.statusCritical
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(hovering ? accent : theme.textTertiary)
                .frame(width: 20, height: 20)
                .background(
                    Circle().fill(hovering ? accent.opacity(0.12) : .clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.15), value: hovering)
        .onHover { hovering = $0 }
        .accessibilityLabel(label)
        .accessibilityHint(hint)
    }
}

private struct DestructiveButton: View {
    let title: String
    let icon: String
    let theme: PanelTheme
    let hint: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 9, weight: .semibold))
                Text(title)
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
            }
            .foregroundStyle(hovering ? theme.accentForeground : theme.statusCritical)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 7)
            .background(
                Capsule().fill(
                    hovering ? theme.statusCritical : theme.statusCritical.opacity(theme.dark ? 0.13 : 0.07)
                )
            )
            .overlay(Capsule().stroke(theme.statusCritical.opacity(0.42), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.15), value: hovering)
        .onHover { hovering = $0 }
        .accessibilityLabel(title)
        .accessibilityHint(hint)
    }
}

private struct UpdateCheckButton: View {
    let checking: Bool
    let theme: PanelTheme
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if checking {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.7)
                        .frame(width: 12, height: 12)
                        .tint(.white)
                } else {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10, weight: .semibold))
                }
                Text(checking ? tr("正在检查…", "Checking…") : tr("检查更新", "Check for Updates"))
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(
                Capsule().fill(
                    LinearGradient(
                        colors: hovering
                            ? [theme.statusHealthy.opacity(0.88), theme.statusHealthy]
                            : [theme.statusHealthy, theme.statusHealthy.opacity(0.82)],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
            )
            .scaleEffect(hovering && !checking ? 1.008 : 1)
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

/// 卡片里的区块。比 `glassCard` 收一号：圆角 8、底色更淡。
///
/// 一张页面只该有一层 14pt 的卡——它是「这是一页」的边界。页内再用同样的卡片，
/// 层级就说不清了。
private struct SectionCard: ViewModifier {
    let theme: PanelTheme

    func body(content: Content) -> some View {
        content
            .background(RoundedRectangle(cornerRadius: 8).fill(theme.glassBackground))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.glassBorder, lineWidth: 1))
    }
}

extension View {
    func glassCard(_ theme: PanelTheme) -> some View { modifier(GlassCard(theme: theme)) }
    func sectionCard(_ theme: PanelTheme) -> some View { modifier(SectionCard(theme: theme)) }
}
