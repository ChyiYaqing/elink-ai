import AppKit
import SwiftUI

final class PanelModel: ObservableObject {
    @Published var claude = AgentStatus()
    @Published var codex = AgentStatus()
    @Published var updatedText = tr("用量更新中…", "Updating usage…")
    @Published var previewImage: NSImage?
    @Published var deviceSummary = tr("正在连接设备…", "Connecting to device…")
    @Published var deviceBadge = tr("连接中", "Connecting")
    @Published var deviceHealthy = false
    @Published var mode = "dashboard"
    @Published var busy = false
    @Published var refreshingUsage = false
    @Published var showSettings = false
    @Published var statsProvider: String?
    @Published var launchAtLogin = false
    @Published var deviceHost = ""
    @Published var bridgeAddress = ""
    @Published var deviceConnectionEnabled = true
    @Published var settingsMessage: String?
    @Published var agentSessions: [AgentSession] = []
    @Published var agentSessionsEnabled = true
    @Published var language: AppLanguage = AppLanguage.current
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
}

struct UsagePanelView: View {
    @ObservedObject var model: PanelModel
    @ObservedObject var updater: UpdateChecker
    @ObservedObject var cluster: ClusterManager
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
    @State private var expandedNodeID: String?

    init(model: PanelModel, updater: UpdateChecker, cluster: ClusterManager,
         initialDeviceSettingsExpanded: Bool = false,
         initialClusterExpanded: Bool = false,
         initialExpandedNodeID: String? = nil) {
        self.model = model
        self.updater = updater
        self.cluster = cluster
        _deviceSettingsExpanded = State(initialValue: initialDeviceSettingsExpanded)
        _clusterExpanded = State(initialValue: initialClusterExpanded)
        _expandedNodeID = State(initialValue: initialExpandedNodeID)
    }

    var body: some View {
        let theme = PanelTheme(scheme)
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
                                         status: model.claude, theme: theme) {
                                Log.user("open Claude usage statistics")
                                withAnimation(.easeOut(duration: 0.2)) { model.statsProvider = "claude" }
                            }
                            ProviderCard(name: "Codex", pet: PixelPet.codex,
                                         accent: PanelTheme.codexColor(dark: theme.dark),
                                         status: model.codex, theme: theme) {
                                Log.user("open Codex usage statistics")
                                withAnimation(.easeOut(duration: 0.2)) { model.statsProvider = "codex" }
                            }
                        }
                        .fixedSize(horizontal: false, vertical: true)
                        if model.agentSessionsEnabled && !model.agentSessions.isEmpty {
                            AgentSessionsCard(sessions: model.agentSessions, theme: theme)
                        }
                        if model.deviceConnectionEnabled || model.showSettings || model.statsProvider != nil {
                            deviceCard(theme)
                        }
                    }
                    .frame(maxWidth: .infinity)
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
        .frame(maxHeight: model.panelMaxHeight)
        .background(theme.backgroundGradient)
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
                    agentSessionsSettings(theme)
                    clusterSettings(theme)
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
                        color: Color(red: 0.35, green: 0.60, blue: 0.95),
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
                           color: Color(red: 0.28, green: 0.66, blue: 0.62),
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
            .frame(width: 140)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(theme)
    }

    private func agentSessionsSettings(_ theme: PanelTheme) -> some View {
        HStack(spacing: 8) {
            settingsHeader(theme, icon: "terminal.fill",
                           color: Color(red: 0.55, green: 0.40, blue: 0.90),
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
                    color: Color(red: 0.32, green: 0.58, blue: 0.96),
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
                                    .foregroundStyle(Color(red: 0.32, green: 0.58, blue: 0.96))
                                    .frame(width: 24, height: 24)
                                    .background(Circle().fill(Color.blue.opacity(theme.dark ? 0.18 : 0.09)))
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
                                            ? Color.green
                                            : Color(red: 0.32, green: 0.58, blue: 0.96))
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
                                    .fill(Color.blue.opacity(theme.dark ? 0.10 : 0.05))
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
                                    .foregroundStyle(Color(red: 0.32, green: 0.58, blue: 0.96))
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
                            theme: theme
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
                                                    peers: cluster.discoveredPeers), id: \.label) { row in
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
                .foregroundStyle(online ? Color(red: 0.32, green: 0.58, blue: 0.96) : theme.textTertiary)
                .frame(width: 26, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 7)
                        .fill((online ? Color.blue : theme.textTertiary).opacity(theme.dark ? 0.16 : 0.08))
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

    struct ClusterNodeDetailRow: Equatable {
        let label: String
        let value: String
    }

    /// 节点详情：连接地址优先用已记录的 endpoint，其次用 Bonjour 发现结果，本机则用局域网地址
    static func clusterNodeDetails(_ node: ClusterNodeRecord, isLocal: Bool,
                                   localEndpoint: String?,
                                   peers: [DiscoveredClusterPeer]) -> [ClusterNodeDetailRow] {
        let address = isLocal
            ? localEndpoint
            : (node.endpoint ?? peers.first { $0.nodeID == node.nodeID }?.endpoint)
        var rows = [
            ClusterNodeDetailRow(label: tr("连接地址", "Address"),
                                 value: address ?? tr("未知", "Unknown")),
            ClusterNodeDetailRow(label: tr("节点 ID", "Node ID"), value: node.nodeID)
        ]
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
            : working ? Color(red: 0.32, green: 0.58, blue: 0.96) : theme.statusHealthy
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
            settingsHeader(theme, icon: "doc.text.fill", color: Color(red: 0.55, green: 0.52, blue: 0.62),
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
                    .disabled(updater.isChecking)

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
                        WideButton(title: tr("下载 v\(updater.latestVersion ?? "最新版") DMG",
                                             "Download v\(updater.latestVersion ?? "latest") DMG"),
                                   icon: "arrow.down.to.line.compact", theme: theme) {
                            updater.openAvailableUpdate()
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
                Text(UsagePresentation.missingPrimaryText(status))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(theme.textTertiary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
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
            if status.tokensToday > 0 {
                HStack(spacing: 3) {
                    Image(systemName: "number.circle.fill")
                        .font(.system(size: 7))
                    Text(tr("今日 \(UsageFormat.tokens(status.tokensToday)) tokens", "Today \(UsageFormat.tokens(status.tokensToday)) tokens"))
                        .font(.system(size: 9, weight: .medium))
                }
                .foregroundStyle(theme.textSecondary)
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

    private func resetLine(_ minutes: Int?) -> some View {
        HStack(spacing: 3) {
            Image(systemName: "clock.fill").font(.system(size: 7))
            Text(minutes.map { tr("\(MenuBarController.formatMinutes($0)) 后重置", "resets in \(MenuBarController.formatMinutes($0))") } ?? tr("无活跃窗口", "No active window"))
                .font(.system(size: 8, weight: .medium))
        }
        .foregroundStyle(theme.textTertiary)
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

private struct DestructiveButton: View {
    let title: String
    let icon: String
    let theme: PanelTheme
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
            .foregroundStyle(hovering ? Color.white : theme.statusCritical)
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
        .accessibilityHint(tr("停止与其他主机同步，本机历史数据会保留",
                              "Stops syncing with other hosts; this host's history is kept"))
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

extension View {
    func glassCard(_ theme: PanelTheme) -> some View { modifier(GlassCard(theme: theme)) }
}
