import SwiftUI

/// 主页那张 VPS 卡：两台机器各一块，只回答「现在有没有问题」。
///
/// 每台只放内存、磁盘、流量三条。四条 × 两台会让首页变成一片进度条，而 swap 是四项里
/// 最不需要一眼判断的——截图那台 99/521 MB 就完全正常。swap、负载、IP、重置日都在
/// 点开之后的那一页。
struct VpsCard: View {
    @ObservedObject var monitor: KiwiVMMonitor
    let theme: PanelTheme
    let onOpen: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: onOpen) {
                // 紧凑头部：与 Nebula、电子纸两张卡保持同一套样式，折叠时三张同高。
                HStack(spacing: 6) {
                    Image(systemName: "server.rack")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(theme.textSecondary)
                    Text(tr("服务器", "Servers"))
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(theme.textPrimary)
                    Spacer()
                    StateBadge(text: "\(runningCount)/\(monitor.servers.count)",
                               color: healthy ? theme.statusHealthy : theme.statusWarning)
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
            .accessibilityLabel(tr("服务器", "Servers"))
            .accessibilityHint(tr("展开完整的 VPS 视图", "Opens the full VPS view"))

            VStack(alignment: .leading, spacing: 5) {
                Text(Self.subtitle(total: monitor.servers.count, running: runningCount,
                                   updatedAt: monitor.updatedAt))
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(theme.textTertiary)
                if monitor.servers.isEmpty {
                    Text(tr("正在读取 KiwiVM…", "Reading from KiwiVM…"))
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(theme.textTertiary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 5)

            VStack(alignment: .leading, spacing: 10) {
                ForEach(monitor.servers, id: \.veid) { server in
                    serverBlock(server)
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 12)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(theme)
    }

    private var runningCount: Int { monitor.servers.filter(\.isRunning).count }

    private var healthy: Bool {
        !monitor.servers.isEmpty
            && monitor.servers.allSatisfy(\.isRunning)
            && monitor.failures.isEmpty
    }

    private func serverBlock(_ server: VpsSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(server.label)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(1)
                StateBadge(text: Self.stateText(server.state),
                           color: Self.stateColor(server.state, theme: theme))
                Spacer(minLength: 0)
                Text(server.location)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(theme.textTertiary)
                    .lineLimit(1)
            }

            if let notice = Self.notice(for: server, failure: monitor.failures[server.veid]) {
                Text(notice)
                    .font(.system(size: 8, weight: .medium))
                    .foregroundStyle(theme.statusWarning)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // 停机时不画三条 0%：那和「真的空着」是两件事。
            if server.isRunning || server.memory != nil || server.disk != nil {
                HStack(alignment: .top, spacing: 8) {
                    gauge(tr("内存", "RAM"), server.memory)
                    gauge(tr("磁盘", "Disk"), server.disk)
                    gauge(tr("流量", "Data"), server.bandwidth)
                }
            }
        }
    }

    @ViewBuilder
    private func gauge(_ label: String, _ pair: VpsUsagePair?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 3) {
                Text(label)
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(theme.textSecondary)
                Spacer(minLength: 0)
                Text(pair.map { "\(Int($0.usedPercent.rounded()))%" } ?? "—")
                    .font(.system(size: 8, weight: .semibold, design: .monospaced))
                    .foregroundStyle(theme.textTertiary)
            }
            UsageBar(percent: pair?.usedPercent ?? 0, theme: theme)
            Text(pair.map { VpsFormat.pair($0) } ?? tr("无读数", "no reading"))
                .font(.system(size: 8, design: .monospaced))
                .foregroundStyle(theme.textTertiary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - 文案
    //
    // 全部是静态纯函数，理由与 `UsagePanelView.meshSubtitle` 相同：这些判定要能在
    // 不起 UI 的情况下断言，而它们恰恰是最容易把两种原因说成同一件事的地方。

    /// 数据年龄必须写出来。一个五分钟前的「运行中」和刚读到的长得一模一样，
    /// 而这张卡就是用来判断「现在怎么样」的。
    static func subtitle(total: Int, running: Int, updatedAt: Date?,
                         now: Date = Date()) -> String {
        let head = running == total
            ? tr("\(total) 台 · 均在运行", "\(total) server(s) · all running")
            : tr("\(total) 台 · \(running) 台在运行", "\(total) server(s) · \(running) running")
        guard let updatedAt else { return head + tr(" · 尚未读取", " · not read yet") }
        let age = Int(max(0, now.timeIntervalSince(updatedAt)))
        let ago = age < 60
            ? tr("\(age) 秒前", "\(age)s ago")
            : tr("\(age / 60) 分钟前", "\(age / 60)m ago")
        return head + " · " + ago
    }

    static func stateText(_ state: VpsRunState) -> String {
        switch state {
        case .running: return tr("运行中", "running")
        case .stopped: return tr("已停止", "stopped")
        case .starting: return tr("启动中", "starting")
        case .suspended: return tr("已暂停", "suspended")
        case .unknown: return tr("状态未知", "unknown")
        }
    }

    static func stateColor(_ state: VpsRunState, theme: PanelTheme) -> Color {
        switch state {
        case .running: return theme.statusHealthy
        case .stopped, .unknown: return theme.textTertiary
        case .starting: return theme.statusInfo
        case .suspended: return theme.statusCritical
        }
    }

    /// 每一种反常都要有自己的一句话。把「api_key 被拒」说成「连不上」，会把一个去设置页
    /// 两秒就能修好的问题引向排查网络；而 KiwiVM 超出点数配额时同样是不回包，所以
    /// 「连不上」这句必须同时容得下这两种可能，不能咬定是网络。
    static func notice(for server: VpsSnapshot?, failure: VpsFetchError?,
                       now: Date = Date()) -> String? {
        if let failure {
            let age = server.map { Int(max(0, now.timeIntervalSince($0.fetchedAt)) / 60) }
            let stale = age.map { $0 < 1
                ? tr("，显示的是刚才的读数", ", showing the reading from moments ago")
                : tr("，显示的是 \($0) 分钟前的读数", ", showing the reading from \($0)m ago") } ?? ""
            switch failure {
            case .rejected:
                return tr("KiwiVM 拒绝了这台的 API key，请到设置里更新",
                          "KiwiVM rejected this server's API key; update it in settings")
            case .unreachable:
                return tr("连不上 KiwiVM（也可能是调用点数用尽）\(stale)",
                          "Cannot reach KiwiVM (its rate limit may also be exhausted)\(stale)")
            case .malformed:
                return tr("KiwiVM 返回了看不懂的内容\(stale)",
                          "KiwiVM returned something unreadable\(stale)")
            }
        }
        guard let server else { return nil }
        if server.state == .suspended {
            return tr("KiwiVM 报告此服务被暂停", "KiwiVM reports this service as suspended")
        }
        if !server.supportsLiveMetrics {
            return tr("这台是 \(server.vmType.rawValue.uppercased())，本版本只读取 KVM 的实时用量",
                      "This is \(server.vmType.rawValue.uppercased()); only KVM live metrics are read")
        }
        if server.state == .stopped { return tr("已停止 · 无实时读数", "Stopped · no live readings") }
        if server.cpuThrottled { return tr("CPU 正在被限流", "CPU is being throttled") }
        return nil
    }
}

/// 字节量的呈现。
enum VpsFormat {
    /// 「已用 / 总量」。
    ///
    /// 两个数必须同单位同精度，否则 `13.33G / 20480M` 读起来像是哪一边算错了。
    /// 单位由**已用量**决定而不是总量：1 GiB 内存用掉 347 MB，按总量选出的单位会写成
    /// `0.34 / 1G`——那一行里最该读出来的数字被压没了。已用为 0 时才回头看总量。
    static func pair(_ pair: VpsUsagePair) -> String {
        let unit = self.unit(for: pair.usedBytes > 0 ? pair.usedBytes : pair.totalBytes)
        return "\(value(pair.usedBytes, unit: unit)) / \(value(pair.totalBytes, unit: unit))\(unit.suffix)"
    }

    static func bytes(_ value: Int64) -> String {
        let unit = self.unit(for: value)
        return "\(self.value(value, unit: unit))\(unit.suffix)"
    }

    enum Unit {
        case megabytes, gigabytes, terabytes

        var scale: Double {
            switch self {
            case .megabytes: return Double(1 << 20)
            case .gigabytes: return Double(1 << 30)
            case .terabytes: return Double(1 << 40)
            }
        }

        var suffix: String {
            switch self {
            case .megabytes: return "M"
            case .gigabytes: return "G"
            case .terabytes: return "T"
            }
        }
    }

    static func unit(for bytes: Int64) -> Unit {
        if bytes >= 1 << 40 { return .terabytes }
        if bytes >= 1 << 30 { return .gigabytes }
        return .megabytes
    }

    /// 两位小数，与 KiwiVM 面板一致——照抄它的精度，是为了让用户能把两屏上的数字
    /// 直接对上，而不是去判断差的那一位是谁算错了。整数不写小数点：`20.00G` 只会
    /// 让人怀疑那是不是一个算出来的近似值。
    static func value(_ bytes: Int64, unit: Unit) -> String {
        let scaled = Double(bytes) / unit.scale
        if scaled == scaled.rounded() { return String(format: "%.0f", scaled) }
        return String(format: "%.2f", scaled)
    }
}
