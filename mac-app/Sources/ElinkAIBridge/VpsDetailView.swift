import SwiftUI

/// VPS 详情页：把 KiwiVM 面板上那一屏原样搬过来。
///
/// 比 `MeshDetailView` 简单得多，因为这里没有历史——KiwiVM 给的是当下的读数，
/// 没有可画的曲线，也就没有窗口选择和时间轴。
struct VpsDetailView: View {
    @ObservedObject var monitor: KiwiVMMonitor
    let theme: PanelTheme
    /// (veid, 新名字)。名字只存在本机，改它不需要再问 KiwiVM。
    let onRename: (String, String) -> Void
    let onBack: () -> Void
    @State private var renamingVeid: String?
    @State private var labelDraft = ""
    @FocusState private var labelFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 12) {
                    if monitor.servers.isEmpty {
                        Text(tr("等待第一次读取…", "Waiting for the first reading…"))
                            .font(.system(size: 11))
                            .foregroundStyle(theme.textTertiary)
                            .padding(.vertical, 24)
                    }
                    ForEach(monitor.servers, id: \.veid) { server in
                        serverBlock(server)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // 点进来常常正是因为怀疑出了问题，先补一轮；守卫在 monitor 里，不会变成连发。
        .onAppear { monitor.refreshIfStale() }
    }

    private var header: some View {
        HStack(spacing: 8) {
            PillButton(title: tr("返回", "Back"), icon: "chevron.left", theme: theme, action: onBack)
            Image(systemName: "server.rack")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(theme.textSecondary)
            Text(tr("服务器", "Servers"))
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundStyle(theme.textPrimary)
            Spacer()
            Text(VpsCard.subtitle(total: monitor.servers.count,
                                  running: monitor.servers.filter(\.isRunning).count,
                                  updatedAt: monitor.updatedAt))
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(theme.textTertiary)
        }
    }

    private func serverBlock(_ server: VpsSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                if renamingVeid == server.veid {
                    TextField(tr("名称", "Name"), text: $labelDraft)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .frame(maxWidth: 160)
                        .focused($labelFocused)
                        .onSubmit { commitRename(server.veid) }
                        .onExitCommand { renamingVeid = nil }
                        // 点到别处也算确认：留着一个没人管的输入框比悄悄保存更让人困惑。
                        .onChange(of: labelFocused) { focused in
                            if !focused { commitRename(server.veid) }
                        }
                } else {
                    Text(server.label)
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundStyle(theme.textPrimary)
                    Button {
                        labelDraft = server.label
                        renamingVeid = server.veid
                        labelFocused = true
                    } label: {
                        Image(systemName: "pencil")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(theme.textTertiary)
                            .frame(width: 16, height: 16)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(tr("重命名 \(server.label)", "Rename \(server.label)"))
                }
                Text(server.plan)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(theme.textTertiary)
                Spacer(minLength: 0)
                StateBadge(text: VpsCard.stateText(server.state),
                           color: VpsCard.stateColor(server.state, theme: theme))
            }

            if let notice = VpsCard.notice(for: server, failure: monitor.failures[server.veid]) {
                Text(notice)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(theme.statusWarning)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 7) {
                bar(tr("内存", "RAM"), server.memory)
                bar(tr("Swap", "Swap"), server.swap)
                bar(tr("磁盘", "Disk"), server.disk)
                bar(tr("流量", "Data"), server.bandwidth,
                    footnote: bandwidthFootnote(server))
            }

            VStack(alignment: .leading, spacing: 3) {
                field(tr("物理位置", "Location"), server.location)
                field(tr("Node ID", "Node ID"), [server.nodeAlias, server.nodeIP]
                    .filter { !$0.isEmpty }.joined(separator: " · "))
                field(tr("VM ID", "VM ID"), server.veid)
                field(tr("公网 IP", "Public IP"), server.ipAddresses.joined(separator: ", "))
                field(tr("SSH 端口", "SSH Port"),
                      server.sshPort.map(String.init) ?? tr("不可用", "unavailable"))
                field(tr("操作系统", "Operating system"), server.os)
                field(tr("主机名", "Hostname"), server.hostname)
                field(tr("负载", "Load"), server.loadAverage ?? "")
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(theme)
    }

    /// 先清掉编辑态再回调：失焦也会走到这里，守卫保证回车 + 失焦只保存一次，
    /// Esc 取消后的那次失焦什么也不做。
    private func commitRename(_ veid: String) {
        guard renamingVeid == veid else { return }
        renamingVeid = nil
        let current = monitor.servers.first { $0.veid == veid }?.label
        guard labelDraft.trimmingCharacters(in: .whitespacesAndNewlines) != current else { return }
        onRename(veid, labelDraft)
    }

    @ViewBuilder
    private func bar(_ label: String, _ pair: VpsUsagePair?, footnote: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(label)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(theme.textSecondary)
                    .frame(width: 44, alignment: .leading)
                UsageBar(percent: pair?.usedPercent ?? 0, theme: theme)
                Text(pair.map { VpsFormat.pair($0) } ?? tr("无读数", "no reading"))
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(theme.textTertiary)
                    .frame(width: 96, alignment: .trailing)
            }
            if let footnote {
                Text(footnote)
                    .font(.system(size: 8, weight: .medium))
                    .foregroundStyle(theme.textTertiary)
                    .padding(.leading, 50)
            }
        }
    }

    private func bandwidthFootnote(_ server: VpsSnapshot) -> String? {
        var parts: [String] = []
        if let reset = server.bandwidthResetAt {
            parts.append(Self.resetText(reset))
        }
        // 倍率不等于 1 时必须说出来，否则用户会拿这个配额去除自己实际传输的字节。
        if server.bandwidthMultiplier != 1 {
            let rate = server.bandwidthMultiplier == server.bandwidthMultiplier.rounded()
                ? String(format: "%.0f", server.bandwidthMultiplier)
                : String(format: "%g", server.bandwidthMultiplier)
            parts.append(tr("按 \(rate) 倍计费", "billed at \(rate)× the transferred volume"))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    @ViewBuilder
    private func field(_ label: String, _ value: String) -> some View {
        if !value.isEmpty {
            HStack(alignment: .top, spacing: 6) {
                Text(label)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(theme.textTertiary)
                    .frame(width: 72, alignment: .leading)
                Text(value)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(theme.textSecondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
        }
    }

    /// 重置日既要给日期也要给剩余天数：日期回答「什么时候」，天数回答「还来不来得及」，
    /// 而后者才是看这一行的原因。
    static func resetText(_ date: Date, now: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: AppLanguage.current == .chinese ? "zh_CN" : "en_US")
        formatter.setLocalizedDateFormatFromTemplate("MMMd")
        let day = formatter.string(from: date)
        let days = Calendar.current.dateComponents([.day], from: now, to: date).day ?? 0
        if days < 0 { return tr("\(day) 已重置", "reset on \(day)") }
        if days == 0 { return tr("今天重置", "resets today") }
        return tr("\(day) 重置 · 还有 \(days) 天", "resets \(day) · \(days) days left")
    }
}
