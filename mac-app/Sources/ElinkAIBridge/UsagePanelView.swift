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
    @Published var refreshingUsage = false
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
    @ObservedObject var updater: UpdateChecker
    @ObservedObject var cluster: ClusterManager
    @Environment(\.colorScheme) private var scheme
    @State private var updatesExpanded = false
    @State private var clusterExpanded = false
    @State private var clusterAddress = ""
    @State private var clusterCode = ""
    @State private var clusterMessage: String?
    @State private var showClusterAdvanced = false
    @State private var showLeaveClusterConfirmation = false

    init(model: PanelModel, updater: UpdateChecker, cluster: ClusterManager,
         initialClusterExpanded: Bool = false) {
        self.model = model
        self.updater = updater
        self.cluster = cluster
        _clusterExpanded = State(initialValue: initialClusterExpanded)
    }

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
                    text: "\(max(1, cluster.nodes.filter { $0.isOnline() }.count))/\(max(1, cluster.nodes.count)) 台",
                    color: cluster.nodes.allSatisfy { $0.isOnline() }
                        ? theme.statusHealthy : theme.statusWarning
                )
            }
            PillButton(title: model.refreshingUsage ? "刷新中" : "刷新",
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
                Text("设置")
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundStyle(theme.textPrimary)
                HStack {
                    PillButton(title: "返回", icon: "chevron.left", theme: theme) {
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
                        Log.user("launch at login \(enabled ? "enabled" : "disabled")")
                    } catch {
                        Log.warning("set launch at login failed: \(error.localizedDescription)", category: "user")
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

    private func clusterSettings(_ theme: PanelTheme) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeOut(duration: 0.2)) {
                    clusterExpanded.toggle()
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(theme.textTertiary)
                        .rotationEffect(.degrees(clusterExpanded ? 90 : 0))
                    settingsHeader(
                        theme,
                        icon: "macbook.and.iphone",
                        color: Color(red: 0.32, green: 0.58, blue: 0.96),
                        title: "多机同步",
                        subtitle: cluster.enabled
                            ? "\(max(1, cluster.nodes.filter { $0.isOnline() }.count))/\(max(1, cluster.nodes.count)) 台在线"
                            : "独立模式 · 本机数据不会广播"
                    )
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(clusterExpanded ? "已展开" : "已折叠")

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
                                    Text("在另一台 Mac 输入配对码")
                                        .font(.system(size: 9, weight: .semibold, design: .rounded))
                                        .foregroundStyle(theme.textPrimary)
                                    Text("两分钟内有效")
                                        .font(.system(size: 8, weight: .medium))
                                        .foregroundStyle(theme.textTertiary)
                                }
                                Spacer()
                                Text(code)
                                    .font(.system(size: 16, weight: .bold, design: .monospaced))
                                    .foregroundStyle(theme.textPrimary)
                                    .textSelection(.enabled)
                            }
                            .padding(8)
                            .background(
                                RoundedRectangle(cornerRadius: 9)
                                    .fill(Color.blue.opacity(theme.dark ? 0.10 : 0.05))
                            )
                        }

                        HStack(spacing: 8) {
                            PillButton(
                                title: cluster.syncing ? "同步中" : "立即同步",
                                icon: "arrow.triangle.2.circlepath",
                                theme: theme
                            ) {
                                clusterMessage = "正在同步…"
                                cluster.syncAll { error in
                                    clusterMessage = error.map { "同步失败：\($0.localizedDescription)" }
                                        ?? "同步完成"
                                }
                            }
                            .disabled(cluster.syncing)
                            PillButton(
                                title: cluster.pairingCode == nil ? "添加 Mac" : "停止配对",
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
                                    Text("加入已有同步集群")
                                        .font(.system(size: 9, weight: .semibold, design: .rounded))
                                        .foregroundStyle(theme.textPrimary)
                                    Text("输入另一台 Mac 显示的地址和 6 位配对码")
                                        .font(.system(size: 8, weight: .medium))
                                        .foregroundStyle(theme.textTertiary)
                                }
                            }

                            Text("加入后将替换本机的单节点集群配置，本机历史用量会保留。")
                                .font(.system(size: 8, weight: .medium))
                                .foregroundStyle(theme.statusWarning)
                            clusterJoinFields(theme, buttonTitle: "加入已有集群")
                        }

                        if let message = clusterMessage ?? cluster.lastError {
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
                                Text("高级连接")
                                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                                Spacer()
                                Text("VPN 手动地址")
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
                                    TextField("已配对节点地址，例如 10.1.7.106:8765", text: $clusterAddress)
                                        .textFieldStyle(.roundedBorder)
                                        .font(.system(size: 9, design: .monospaced))
                                    PillButton(title: "连接", icon: "link", theme: theme) {
                                        let address = clusterAddress
                                        clusterMessage = "正在连接 \(address)…"
                                        cluster.addManualEndpoint(address)
                                        cluster.syncAll { error in
                                            if let error {
                                                clusterMessage = "连接失败：\(error.localizedDescription)"
                                            } else {
                                                clusterMessage = "已连接并完成同步"
                                                clusterAddress = ""
                                            }
                                        }
                                    }
                                    .disabled(clusterAddress.isEmpty)
                                }
                                Text("仅用于已经完成配对、但 Bonjour 无法发现的 VPN 节点。")
                                    .font(.system(size: 8, weight: .medium))
                                    .foregroundStyle(theme.textTertiary)
                            }
                            .transition(.opacity)
                        }

                        DestructiveButton(
                            title: "离开同步集群",
                            icon: "rectangle.portrait.and.arrow.right",
                            theme: theme
                        ) { showLeaveClusterConfirmation = true }
                    } else {
                        WideButton(title: "创建同步集群", icon: "plus.circle", theme: theme) {
                            cluster.createCluster()
                            clusterMessage = "同步集群已创建，可在此生成配对码"
                        }

                        Divider().opacity(0.4)

                        clusterJoinFields(theme, buttonTitle: "加入同步集群")
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
        .alert("离开同步集群？", isPresented: $showLeaveClusterConfirmation) {
            Button("取消", role: .cancel) {}
            Button("离开", role: .destructive) { cluster.leaveCluster() }
        } message: {
            Text("本机将停止同步；本地采集数据不会删除。重新加入需要新的配对码。")
        }
    }

    private func clusterNodeRow(_ node: ClusterNodeRecord, theme: PanelTheme) -> some View {
        let local = node.nodeID == cluster.nodeID
        let online = node.isOnline()
        return HStack(spacing: 8) {
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
                        Text("本机")
                            .font(.system(size: 7, weight: .bold, design: .rounded))
                            .foregroundStyle(theme.textSecondary)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(theme.glassBackground))
                    }
                }
                Text(local
                     ? "本机节点"
                     : node.lastSyncAt.map { "同步于 \($0.formatted(date: .omitted, time: .shortened))" }
                        ?? (online ? "已连接，等待首次同步" : "尚未同步"))
                    .font(.system(size: 8, weight: .medium))
                    .foregroundStyle(theme.textTertiary)
            }
            Spacer(minLength: 6)
            StateBadge(
                text: online ? "在线" : "离线",
                color: online ? theme.statusHealthy : theme.textTertiary
            )
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 9)
                .fill(theme.glassBackground.opacity(theme.dark ? 0.72 : 0.58))
        )
    }

    private func clusterFeedback(_ message: String, forceError: Bool,
                                 theme: PanelTheme) -> some View {
        let failed = forceError || ["失败", "错误", "无法", "不属于", "尚无"]
            .contains { message.contains($0) }
        let working = message.contains("正在")
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

    @ViewBuilder
    private func clusterJoinFields(_ theme: PanelTheme, buttonTitle: String) -> some View {
        TextField("集群主机地址，例如 macbook.local:8765", text: $clusterAddress)
            .textFieldStyle(.roundedBorder)
            .font(.system(size: 10, design: .monospaced))
            .onSubmit { joinClusterFromFields() }
        TextField("6 位配对码（填满后自动加入）", text: $clusterCode)
            .textFieldStyle(.roundedBorder)
            .font(.system(size: 10, design: .monospaced))
            .onSubmit { joinClusterFromFields() }
            .onChange(of: clusterCode) { value in
                let digits = String(value.filter(\.isNumber).prefix(6))
                if digits != value {
                    clusterCode = digits
                    return
                }
                if digits.count == 6,
                   !clusterAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    joinClusterFromFields()
                }
            }
        Text("在集群主机点击“添加 Mac”生成配对码；验证码有效期为两分钟。")
            .font(.system(size: 8, weight: .medium))
            .foregroundStyle(theme.textTertiary)
        if let peer = cluster.discoveredPeers.first(where: { $0.pairable }) {
            Button("使用已发现的 \(peer.name)") {
                clusterAddress = peer.endpoint
                if clusterCode.count == 6 { joinClusterFromFields() }
            }
            .buttonStyle(.plain)
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(theme.textSecondary)
        }
        WideButton(title: buttonTitle, icon: "link.badge.plus", theme: theme) {
            joinClusterFromFields()
        }
        .disabled(model.busy)
    }

    private func joinClusterFromFields() {
        guard !model.busy else { return }
        model.busy = true
        clusterMessage = "正在安全配对…"
        cluster.joinCluster(endpoint: clusterAddress, code: clusterCode) { error in
            model.busy = false
            if let error {
                clusterMessage = "配对失败：\(error.localizedDescription)"
            } else {
                clusterMessage = "配对成功，正在同步其他 Mac 的历史用量"
                clusterAddress = ""
                clusterCode = ""
            }
        }
    }

    private func logSettings(_ theme: PanelTheme) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            settingsHeader(theme, icon: "doc.text.fill", color: Color(red: 0.55, green: 0.52, blue: 0.62),
                           title: "日志", subtitle: "查看桥接应用运行日志")
            WideButton(title: "打开日志文件", icon: "doc.text", theme: theme) {
                let url = Log.fileURL()
                Log.user("open log file in Console \(url.path)")
                Log.flush()
                if NSWorkspace.shared.open(url) {
                    model.settingsMessage = "日志文件：\(url.path)"
                } else {
                    Log.warning("Console failed to open log file \(url.path)", category: "user")
                    model.settingsMessage = "无法使用 Console 打开日志文件：\(url.path)"
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
                Log.user("open project page on GitHub")
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

    private func updateSettings(_ theme: PanelTheme) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeOut(duration: 0.2)) {
                    updatesExpanded.toggle()
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(theme.textTertiary)
                        .rotationEffect(.degrees(updatesExpanded ? 90 : 0))
                    settingsHeader(theme, icon: "arrow.down.circle.fill", color: theme.statusHealthy,
                                   title: "软件更新", subtitle: "当前版本 \(updater.currentVersion)")
                }
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
                        WideButton(title: "下载 v\(updater.latestVersion ?? "最新版") DMG",
                                   icon: "arrow.down.to.line.compact", theme: theme) {
                            updater.openAvailableUpdate()
                        }
                    }

                    if let lastCheckedAt = updater.lastCheckedAt {
                        HStack(spacing: 4) {
                            Image(systemName: "clock.fill").font(.system(size: 8))
                            Text("上次检查：\(lastCheckedAt.formatted(date: .abbreviated, time: .shortened))")
                                .font(.system(size: 9, weight: .medium))
                        }
                        .foregroundStyle(theme.textTertiary)
                    }

                    Divider().opacity(0.4)

                    updateToggle(
                        title: "自动检查更新",
                        subtitle: "打开菜单时定期检查 GitHub Releases",
                        isOn: Binding(
                            get: { updater.automaticallyChecks },
                            set: { updater.setAutomaticallyChecks($0) }
                        ),
                        theme: theme
                    )
                    updateToggle(
                        title: "包含测试版本",
                        subtitle: "同时检查 GitHub prerelease 版本",
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
        if updater.isChecking { return "正在检查 GitHub Releases…" }
        switch updater.state {
        case .idle: return "尚未检查更新"
        case .upToDate: return "已是最新版"
        case .updateAvailable: return "发现新版本 v\(updater.latestVersion ?? "")"
        case let .failed(message): return "检查失败：\(message)"
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
    static func missingPrimaryText(_ status: AgentStatus) -> String {
        if status.weekly.percent != nil { return "当前无活跃的 5 小时窗口" }
        return status.error ?? "暂无用量数据"
    }

    static func freshnessText(_ status: AgentStatus, now: Date = Date()) -> String? {
        guard let fetchedAt = status.usageFetchedAt else { return nil }
        let age = max(0, Int(now.timeIntervalSince(fetchedAt)))
        let relative = age < 5 ? "刚刚" : "\(PreviewPopoverController.formatAge(age))前"
        return status.usageCached ? "缓存 · \(relative)" : "\(relative)更新"
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
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text("—")
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                        .foregroundStyle(theme.textTertiary)
                    Spacer()
                    Text("5 小时")
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
            if let error = status.error,
               status.primary.percent != nil || status.weekly.percent != nil {
                HStack(spacing: 3) {
                    Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 7))
                    Text("更新失败 · \(error)")
                        .font(.system(size: 8, weight: .semibold))
                        .lineLimit(2)
                }
                .foregroundStyle(theme.statusWarning)
                .help(error)
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
                    Text("今日 \(UsageFormat.tokens(status.tokensToday)) tokens")
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
        .accessibilityHint("停止与其他 Mac 同步，本机历史数据会保留")
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
                Text(checking ? "正在检查…" : "检查更新")
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

private extension View {
    func glassCard(_ theme: PanelTheme) -> some View { modifier(GlassCard(theme: theme)) }
}
