import SwiftUI

/// 历史窗口长度。
///
/// 默认一小时：五分钟一个桶，一小时是十二格，刚断的那一下在这个尺度上占满一格，一眼
/// 就能看见。更长的窗口回答的是另一个问题——「昨晚是不是断了」——需要时手动切过去。
enum MeshHistorySpan: String, CaseIterable, Identifiable {
    case hour, sixHours, day

    var id: String { rawValue }

    var seconds: TimeInterval {
        switch self {
        case .hour: return 3600
        case .sixHours: return 6 * 3600
        case .day: return 24 * 3600
        }
    }

    var label: String {
        switch self {
        case .hour: return "1h"
        case .sixHours: return "6h"
        case .day: return "24h"
        }
    }
}

final class MeshDetailModel: ObservableObject {
    @Published var span: MeshHistorySpan = .hour
    @Published var localHistory: [String: [MeshBucketPoint]] = [:]
    @Published var lighthouseHistory: [String: [MeshBucketPoint]] = [:]
    @Published var lighthouseError: MeshHistoryError?
    @Published var loading = false
    /// 时间轴的右端。取自加载那一刻并固定下来，否则每次重绘轴都在悄悄右移，
    /// 上下两张图对不齐，读出来的时刻是错的。
    @Published var anchor = Date()
    private var timer: Timer?

    var window: ClosedRange<Date> { anchor.addingTimeInterval(-span.seconds)...anchor }

    deinit { timer?.invalidate() }

    /// 页面开着就自己重载。表头的年龄和状态点跟着 MeshMonitor 走，色带和折线却只在
    /// 打开那一刻取过一次——一张在动的表头配一张冻住的图，比整页都不动更容易看错。
    ///
    /// 节拍对齐探测的 30 秒：更密只是把同一份数据再读一遍，而每次重载都要读一遍库
    /// 并向 lighthouse 要一次历史。
    func startAutoReload(mesh: MeshMonitor, interval: TimeInterval = 30) {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.load(mesh: mesh)
        }
    }

    func stopAutoReload() {
        timer?.invalidate()
        timer = nil
    }

    func load(mesh: MeshMonitor) {
        guard !loading else { return }
        loading = true
        let seconds = span.seconds
        let loadedAt = Date()
        let names = mesh.hosts.map(\.name)
        // 一天 × 六台是上千行，读 SQLite 不放在主线程上，否则翻页时面板会顿一下
        DispatchQueue.global(qos: .userInitiated).async {
            var local: [String: [MeshBucketPoint]] = [:]
            for name in names { local[name] = mesh.history(for: name, window: seconds) }
            DispatchQueue.main.async {
                self.anchor = loadedAt
                self.localHistory = local
            }
        }
        mesh.fetchLighthouseHistory(window: seconds) { [weak self] result in
            guard let self else { return }
            self.loading = false
            switch result {
            case .success(let history):
                self.lighthouseHistory = history
                self.lighthouseError = nil
            case .failure(let error):
                self.lighthouseHistory = [:]
                self.lighthouseError = error
            }
        }
    }
}

/// Nebula overlay 的完整视图。
///
/// 主列表里那张卡只回答「现在几台通」；这里回答「哪条链路、什么时候断的」。和用量统计
/// 一样是面板里的一层覆盖：点卡片进来，点返回回去，不另开窗口。
struct MeshDetailView: View {
    @ObservedObject var mesh: MeshMonitor
    /// lighthouse 地址和出口 NAT 都挂在面板模型上。这一页开着时弹窗仍在轮询，
    /// 那份拷贝跟着一起更新。
    @ObservedObject var panel: PanelModel
    let theme: PanelTheme
    let onBack: () -> Void
    @StateObject private var model = MeshDetailModel()
    @State private var hovered: [String: MeshBucketPoint] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 10) {
                    settings
                    legend
                    if mesh.hosts.isEmpty {
                        Text(tr("等待第一份名册…", "Waiting for the first roster…"))
                            .font(.system(size: 11))
                            .foregroundStyle(theme.textTertiary)
                            .padding(.vertical, 24)
                    }
                    ForEach(mesh.hosts, id: \.name) { host in
                        hostBlock(host)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear {
            // 名册决定这里有哪几台，先补一轮，否则刚开机点进来是空的
            mesh.refreshIfStale()
            model.load(mesh: mesh)
            model.startAutoReload(mesh: mesh)
        }
        .onDisappear { model.stopAutoReload() }
        .onChange(of: model.span) { _ in model.load(mesh: mesh) }
    }

    // MARK: - 顶部

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                PillButton(title: tr("返回", "Back"), icon: "chevron.left", theme: theme,
                           action: onBack)
                Image(systemName: "network")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(theme.textSecondary)
                Text(tr("Nebula 网络", "Nebula Overlay"))
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(theme.textPrimary)
                Spacer()
                PillButton(title: model.loading ? tr("加载中…", "Loading…") : tr("刷新", "Refresh"),
                           icon: "arrow.clockwise", theme: theme) {
                    Log.user("refresh nebula overlay history")
                    mesh.refreshIfStale(maxAge: 0)
                    model.load(mesh: mesh)
                }
                .disabled(model.loading)
            }
            Picker("", selection: $model.span) {
                ForEach(MeshHistorySpan.allCases) { span in
                    Text(span.label).tag(span)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: .infinity)
            Text(UsagePanelView.meshSubtitle(
                total: mesh.hosts.count,
                reachable: mesh.hosts.filter { $0.state == .online }.count,
                updatedAt: mesh.updatedAt
            ))
            .font(.system(size: 9, weight: .medium))
            .foregroundStyle(theme.textTertiary)
            if !mesh.icmpAvailable {
                notice(tr("无法打开 ICMP socket，本机可达性暂时测不了",
                          "No ICMP socket: reachability unavailable on this host"))
            }
            if let text = UsagePanelView.meshRosterNotice(
                configured: mesh.configured, reachable: mesh.lighthouseReachable) {
                notice(text)
            }
        }
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 7) {
            if let nat = UsagePanelView.clusterNatDetail(panel.natObservation,
                                                         unavailable: panel.natUnavailable) {
                HStack(alignment: .top, spacing: 8) {
                    Text(tr("出口 NAT", "Egress NAT"))
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(theme.textTertiary)
                        .frame(width: 62, alignment: .leading)
                    Text(nat)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(theme.textSecondary)
                }
            }
            HStack(spacing: 8) {
                TextField(tr("lighthouse 地址，例如 192.168.100.200:8767",
                             "Lighthouse address, e.g. 192.168.100.200:8767"),
                          text: $panel.lighthouseURL)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 10, design: .monospaced))
                PillButton(title: tr("保存", "Save"), icon: "checkmark", theme: theme) {
                    panel.onSaveLighthouse?(panel.lighthouseURL)
                    model.load(mesh: mesh)
                }
            }
            Text(tr("设备清单由跑着 elink-tui --headless 的 lighthouse 提供；留空则关闭本视图。",
                    "The roster comes from a lighthouse running elink-tui --headless; empty disables this view."))
                .font(.system(size: 8, weight: .medium))
                .foregroundStyle(theme.textTertiary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(theme)
    }

    private var legend: some View {
        let strip = MeshAvailabilityStrip(points: [], window: model.window, theme: theme)
        return HStack(spacing: 10) {
            ForEach([(MeshBucketStatus.ok, tr("全部探通", "all through")),
                     (.partial, tr("有丢包", "some lost")),
                     (.lost, tr("全部不通", "nothing through")),
                     (.noData, tr("没有探测", "not probed"))], id: \.0) { status, text in
                HStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 1)
                        .fill(strip.color(status))
                        .frame(width: 12, height: 8)
                    Text(text)
                        .font(.system(size: 8, weight: .medium))
                        .foregroundStyle(theme.textTertiary)
                }
            }
            Spacer()
        }
    }

    private func notice(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .medium))
            .foregroundStyle(theme.statusWarning)
    }

    // MARK: - 每台节点

    private func hostBlock(_ host: MeshHostView) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            // 440pt 宽放不下「名字 + overlay 地址 + 延迟 + 状态」一行，状态另起一行：
            // 它是四者里最长的，挤在一行会先把 overlay 地址截断
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Circle()
                        .fill(UsagePanelView.meshStateColor(host.state, theme: theme))
                        .frame(width: 6, height: 6)
                    Text(host.name)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(theme.textPrimary)
                    Text(host.overlay)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(theme.textTertiary)
                    Spacer()
                    Text(host.latestRttUs.map { UsagePanelView.meshLatency(Int($0)) } ?? "—")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(theme.textPrimary)
                }
                Text(UsagePanelView.meshStateText(host))
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(UsagePanelView.meshStateColor(host.state, theme: theme))
                    .padding(.leading, 12)
            }

            series(key: "local:\(host.name)",
                   title: tr("本机 → \(host.name)", "this host → \(host.name)"),
                   points: model.localHistory[host.name] ?? [],
                   missing: nil)

            series(key: "lighthouse:\(host.name)",
                   title: tr("lighthouse → \(host.name)", "lighthouse → \(host.name)"),
                   points: model.lighthouseHistory[host.name] ?? [],
                   missing: Self.lighthouseNotice(model.lighthouseError,
                                                  hasSeries: model.lighthouseHistory[host.name] != nil))

            axis
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(theme)
    }

    /// 一条链路的完整呈现：摘要 + 可达性色带 + 延迟折线。
    ///
    /// 色带在折线上方而不是下方：先答「通不通」，再答「快不快」。事故排查里前者是问题
    /// 本身，后者只是旁证。
    @ViewBuilder
    private func series(key: String, title: String, points: [MeshBucketPoint],
                        missing: String?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            // 标题和摘要各占一行：两者并排要 300pt 以上，440pt 的面板里摘要会被吃掉，
            // 而「三分之一探测没回来」正是这一段要说的话
            Text(title)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(theme.textSecondary)
            Text(UsagePanelView.meshHistorySummary(points: points, hovered: hovered[key]))
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(theme.textTertiary)
            if let missing {
                Text(missing)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(theme.statusWarning)
                    .frame(height: 20, alignment: .leading)
            } else {
                MeshAvailabilityStrip(points: points, window: model.window, theme: theme)
                    .frame(height: 10)
                let chart = MeshLatencyChart(points: points, window: model.window,
                                             theme: theme) { point in
                    hovered[key] = point
                }
                chart.frame(height: chart.hasPlottableData ? 56 : 10)
            }
        }
    }

    /// lighthouse 序列缺席时说清是哪一种缺席。
    static func lighthouseNotice(_ error: MeshHistoryError?, hasSeries: Bool) -> String? {
        switch error {
        case .notConfigured:
            return tr("未配置 lighthouse 地址，看不到对端视角",
                      "No lighthouse address: the far-side view is unavailable")
        case .unreachable:
            return tr("lighthouse 取历史失败，只能看到本机视角",
                      "Could not fetch history from the lighthouse: local view only")
        case .unsupported:
            return tr("lighthouse 版本过旧，尚不提供历史（需 elink-tui 支持 /history）",
                      "This lighthouse is too old to serve history (needs elink-tui with /history)")
        case .none:
            return hasSeries ? nil : tr("lighthouse 没有这台设备的探测记录",
                                        "The lighthouse has no probe record for this node")
        }
    }

    private var axis: some View {
        HStack(spacing: 0) {
            ForEach(Array(Self.axisLabels(window: model.window).enumerated()), id: \.offset) { item in
                Text(item.element)
                    .font(.system(size: 8, design: .monospaced))
                    .foregroundStyle(theme.textTertiary)
                    .frame(maxWidth: .infinity,
                           alignment: item.offset == 0 ? .leading
                               : (item.offset == 4 ? .trailing : .center))
            }
        }
    }

    /// 五个等距刻度。满一天的窗口带上日期。
    ///
    /// 门槛正好压在 24 小时上：一天的窗口分五段，首尾两个刻度的时刻必然相同，只写
    /// 「22:13」会在轴的两端印出同一个标签。
    static func axisLabels(window: ClosedRange<Date>, count: Int = 5,
                           locale: Locale = .current) -> [String] {
        let span = window.upperBound.timeIntervalSince(window.lowerBound)
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.setLocalizedDateFormatFromTemplate(span >= 24 * 3600 ? "Mdjmm" : "jmm")
        return (0..<count).map { step in
            let ratio = Double(step) / Double(max(count - 1, 1))
            return formatter.string(from: window.lowerBound.addingTimeInterval(span * ratio))
        }
    }
}
